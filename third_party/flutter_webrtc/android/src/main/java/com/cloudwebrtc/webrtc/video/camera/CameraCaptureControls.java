package com.cloudwebrtc.webrtc.video.camera;

import android.content.Context;
import android.graphics.Rect;
import android.graphics.SurfaceTexture;
import android.hardware.Camera;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureFailure;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.hardware.camera2.params.ColorSpaceTransform;
import android.hardware.camera2.params.RggbChannelVector;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Range;
import android.util.Rational;
import android.view.Surface;

import com.cloudwebrtc.webrtc.GetUserMediaImpl;
import com.cloudwebrtc.webrtc.utils.AnyThreadResult;
import com.cloudwebrtc.webrtc.video.VideoCapturerInfo;

import org.webrtc.Camera1Capturer;
import org.webrtc.Camera1Enumerator;
import org.webrtc.Camera2Capturer;
import org.webrtc.Camera2Enumerator;
import org.webrtc.CameraEnumerationAndroid;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.plugin.common.MethodChannel;

/** Native device controls. All camera work and readback runs on its capture thread. */
public final class CameraCaptureControls {
  private final GetUserMediaImpl media;
  private final Context context;
  private final TorchState torchState;
  // Values deliberately do not retain their weak SDK-session keys.
  private final Map<Object, State> states = new WeakHashMap<>();

  interface TorchState { boolean enabled(); }
  CameraCaptureControls(GetUserMediaImpl media, Context context, TorchState torchState) {
    this.media = media;
    this.context = context;
    this.torchState = torchState;
  }

  private static final class State {
    CaptureRequest request;
    TotalCaptureResult observed;
    Reply pending;
    WhiteBalanceBaseline whiteBalance;
  }
  /** A frozen driver white point, not an invented Kelvin calibration. */
  private static final class WhiteBalanceBaseline {
    final RggbChannelVector gains;
    final ColorSpaceTransform transform;
    final int correctionMode;
    WhiteBalanceBaseline(RggbChannelVector gains, ColorSpaceTransform transform, int correctionMode) {
      this.gains = gains;
      this.transform = transform;
      this.correctionMode = correctionMode;
    }
  }
  private static final class View {
    Object session;
    Handler handler;
    CameraDevice device;
    CameraCaptureSession capture;
    CameraCharacteristics characteristics;
    CameraEnumerationAndroid.CaptureFormat format;
    int fpsUnit;
    Surface surface;
    Camera legacy;
    String cameraId;
  }

  /** Main-thread timeout replies once; work queued after timeout never mutates a camera. */
  private static final class Reply implements MethodChannel.Result {
    final AtomicBoolean completed = new AtomicBoolean();
    final MethodChannel.Result target;
    final Handler main = new Handler(Looper.getMainLooper());
    final Runnable timeout;
    Reply(MethodChannel.Result target) {
      this.target = new AnyThreadResult(target);
      timeout = () -> error("camera-control-timeout", "Camera did not confirm the request", null);
      main.postDelayed(timeout, 3000);
    }
    public void success(Object value) {
      if (!completed.compareAndSet(false, true)) return;
      main.removeCallbacks(timeout);
      target.success(value);
    }
    public void error(String code, String message, Object details) {
      if (!completed.compareAndSet(false, true)) return;
      main.removeCallbacks(timeout);
      target.error(code, message, details);
    }
    public void notImplemented() { error("camera-control-unavailable", "Camera control is unavailable", null); }
  }

  public void get(String trackId, MethodChannel.Result result) { dispatch(trackId, null, result); }
  public void set(String trackId, Map<String, Object> settings, MethodChannel.Result result) {
    if (settings == null || settings.isEmpty()) {
      result.error("invalid-camera-control", "Camera settings must not be empty", null);
      return;
    }
    dispatch(trackId, new HashMap<>(settings), result);
  }

  private void dispatch(String trackId, Map<String, Object> settings, MethodChannel.Result result) {
    final VideoCapturerInfo info = media.getCapturerInfo(trackId);
    if (info == null || info.isScreenCapture ||
        !(info.capturer instanceof Camera1Capturer || info.capturer instanceof Camera2Capturer)) {
      result.error("camera-control-unavailable", "A live camera track is required", null);
      return;
    }
    final Handler cameraHandler;
    try {
      cameraHandler = (Handler) field(info.capturer, "cameraThreadHandler");
      if (cameraHandler == null) throw new IllegalStateException("Camera is opening");
    } catch (ReflectiveOperationException | RuntimeException error) {
      result.error("camera-not-ready", "Camera capture thread is not ready", null);
      return;
    }
    final Reply reply = new Reply(result);
    if (!cameraHandler.post(() -> {
      if (reply.completed.get()) return;
      try {
        if (media.getCapturerInfo(trackId) != info) throw new IllegalStateException("Camera track ended");
        final View view = view(info);
        if (view.legacy != null) {
          if (settings != null) applyLegacy(view.legacy, settings);
          reply.success(snapshotLegacy(view));
          return;
        }
        final State state = state(view.session);
        if (state.pending != null && state.pending.completed.get()) state.pending = null;
        if (settings == null && state.observed != null) {
          reply.success(snapshot(view, state));
          return;
        }
        if (state.pending != null) {
          reply.error("camera-control-busy", "Another camera request is pending", null);
          return;
        }
        final CaptureRequest.Builder builder = builder(view, state);
        WhiteBalanceBaseline whiteBalance = state.whiteBalance;
        if (settings != null) whiteBalance = apply(view, state, builder, settings);
        submit(trackId, info, view, state, builder, reply, whiteBalance);
      } catch (IllegalArgumentException error) {
        reply.error("invalid-camera-control", error.getMessage(), null);
      } catch (ReflectiveOperationException | CameraAccessException | RuntimeException error) {
        reply.error("camera-not-ready", "Camera session is not available: " + error.getMessage(), null);
      }
    })) reply.error("camera-not-ready", "Camera capture thread has closed", null);
  }

  private State state(Object session) {
    State state = states.get(session);
    if (state == null) { state = new State(); states.put(session, state); }
    return state;
  }

  // Called by the existing torch helper on the same capture thread. Once device
  // controls own the repeating request, torch must preserve that request too.
  boolean hasState(VideoCapturerInfo info) {
    try { return states.containsKey(field(info.capturer, "currentSession")); }
    catch (ReflectiveOperationException | RuntimeException error) { return false; }
  }
  void setTorchOnCameraThread(String trackId, VideoCapturerInfo info, boolean enabled,
                             MethodChannel.Result result) {
    final Reply reply = new Reply(result);
    try {
      final View view = view(info);
      if (view.legacy != null) {
        Camera.Parameters parameters = view.legacy.getParameters();
        parameters.setFlashMode(enabled ? Camera.Parameters.FLASH_MODE_TORCH : Camera.Parameters.FLASH_MODE_OFF);
        view.legacy.setParameters(parameters);
        reply.success(null);
        return;
      }
      State state = state(view.session);
      if (state.pending != null && !state.pending.completed.get()) {
        reply.error("camera-control-busy", "Another camera request is pending", null);
        return;
      }
      CaptureRequest.Builder builder = builder(view, state);
      builder.set(CaptureRequest.FLASH_MODE, enabled ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF);
      submit(trackId, info, view, state, builder, reply, state.whiteBalance);
    } catch (ReflectiveOperationException | CameraAccessException | RuntimeException error) {
      reply.error("camera-not-ready", "Camera session is not available", null);
    }
  }

  private void submit(String trackId, VideoCapturerInfo info, View view, State state,
                      CaptureRequest.Builder builder, Reply reply, WhiteBalanceBaseline whiteBalance) throws CameraAccessException {
    final CaptureRequest request = builder.build();
    final CaptureRequest previous = state.request;
    final WhiteBalanceBaseline previousWhiteBalance = state.whiteBalance;
    state.pending = reply;
    state.request = request;
    state.whiteBalance = whiteBalance;
    try {
      view.capture.setRepeatingRequest(request, new CameraCaptureSession.CaptureCallback() {
        @Override public void onCaptureCompleted(CameraCaptureSession session,
                                                 CaptureRequest delivered, TotalCaptureResult observed) {
          if (state.request != delivered) return;
          try {
            if (media.getCapturerInfo(trackId) != info || field(info.capturer, "currentSession") != view.session) {
              reply.error("camera-session-ended", "Camera session changed before confirmation", null);
              if (state.pending == reply) state.pending = null;
              return;
            }
            state.observed = observed;
            if (state.pending == reply) state.pending = null;
            if (!reply.completed.get()) reply.success(snapshot(view, state));
          } catch (ReflectiveOperationException | RuntimeException error) {
            reply.error("camera-session-ended", "Camera session changed before confirmation", null);
          }
        }
        @Override public void onCaptureFailed(CameraCaptureSession session, CaptureRequest delivered, CaptureFailure failure) {
          if (state.request != delivered) return;
          if (state.pending == reply) state.pending = null;
          reply.error("camera-control-failed", "The device rejected a camera capture request", null);
        }
        @Override public void onCaptureSequenceAborted(CameraCaptureSession session, int sequenceId) {
          if (state.request != request || reply.completed.get()) return;
          if (state.pending == reply) state.pending = null;
          reply.error("camera-session-ended", "The camera request was interrupted", null);
        }
      }, view.handler);
    } catch (CameraAccessException | RuntimeException error) {
      if (state.pending == reply) state.pending = null;
      state.request = previous;
      state.whiteBalance = previousWhiteBalance;
      throw error;
    }
  }

  private View view(VideoCapturerInfo info) throws ReflectiveOperationException, CameraAccessException {
    final View view = new View();
    view.session = field(info.capturer, "currentSession");
    if (view.session == null) throw new IllegalStateException("Camera is opening or closed");
    view.handler = (Handler) field(info.capturer, "cameraThreadHandler");
    if (info.capturer instanceof Camera1Capturer) {
      view.legacy = (Camera) field(view.session, "camera");
      view.cameraId = (String)field(info.capturer, "cameraName");
      if (view.legacy == null) throw new IllegalStateException("Camera has closed");
      return view;
    }
    view.device = (CameraDevice) field(view.session, "cameraDevice");
    view.capture = (CameraCaptureSession) field(view.session, "captureSession");
    view.surface = (Surface) field(view.session, "surface");
    view.format = (CameraEnumerationAndroid.CaptureFormat) field(view.session, "captureFormat");
    view.fpsUnit = (Integer) field(view.session, "fpsUnitFactor");
    if (view.device == null || view.capture == null || view.surface == null || view.format == null || view.fpsUnit <= 0)
      throw new IllegalStateException("Camera is opening or closed");
    view.cameraId = view.device.getId();
    CameraManager manager = (CameraManager) field(info.capturer, "cameraManager");
    view.characteristics = manager.getCameraCharacteristics(view.cameraId);
    return view;
  }

  private CaptureRequest.Builder builder(View view, State state) throws CameraAccessException {
    CaptureRequest.Builder builder = view.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
    if (state.request != null) {
      for (CaptureRequest.Key<?> key : state.request.getKeys()) copy(builder, state.request, key);
    } else {
      builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
      builder.set(CaptureRequest.CONTROL_AE_LOCK, false);
      builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
          new Range<>(view.format.framerate.min / view.fpsUnit, view.format.framerate.max / view.fpsUnit));
      if (contains(view.characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES), CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO))
        builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
      // Match WebRTC's stabilization preference when installing the readback callback.
      if (contains(view.characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION), CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)) {
        builder.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON);
        builder.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF);
      } else if (contains(view.characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES), CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)) {
        builder.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON);
      }
      builder.set(CaptureRequest.FLASH_MODE, torchState.enabled() ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF);
    }
    builder.addTarget(view.surface);
    return builder;
  }
  private static <T> void copy(CaptureRequest.Builder builder, CaptureRequest request, CaptureRequest.Key<T> key) {
    T value = request.get(key);
    if (value != null) builder.set(key, value);
  }

  private WhiteBalanceBaseline apply(View view, State state, CaptureRequest.Builder builder, Map<String, Object> settings) {
    for (String key : settings.keySet()) if (!Arrays.asList("zoom", "whiteBalance", "whiteBalanceWarmth", "exposure", "exposureMode", "exposureTimeMs", "iso").contains(key))
      throw new IllegalArgumentException("Unsupported camera setting: " + key);
    CameraCharacteristics camera = view.characteristics;
    WhiteBalanceBaseline whiteBalance = state.whiteBalance;
    Range<Float> zoomRange = ratioRange(camera);
    if (settings.containsKey("zoom")) {
      double zoom = number(settings.get("zoom"));
      double min = zoomRange == null ? 1 : zoomRange.getLower();
      double max = zoomRange == null ? maxDigitalZoom(camera) : zoomRange.getUpper();
      checked(zoom, min, max, "zoom");
      if (max <= min) throw new IllegalArgumentException("Zoom is not supported");
      if (zoomRange != null) {
        builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, (float) zoom);
        Rect active = camera.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
        if (active != null) builder.set(CaptureRequest.SCALER_CROP_REGION, active);
      } else builder.set(CaptureRequest.SCALER_CROP_REGION, crop(camera.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE), zoom));
    }
    if (settings.containsKey("whiteBalance")) {
      if (settings.containsKey("whiteBalanceWarmth")) throw new IllegalArgumentException("Choose automatic/preset white balance or manual warmth, not both");
      Object value = settings.get("whiteBalance");
      if (!(value instanceof String) || !whiteBalanceModes(camera).contains(value))
        throw new IllegalArgumentException("White balance mode is not supported");
      builder.set(CaptureRequest.CONTROL_AWB_MODE, awbValue((String)value));
      if (Boolean.TRUE.equals(camera.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE))) builder.set(CaptureRequest.CONTROL_AWB_LOCK, false);
      if (whiteBalance != null) {
        builder.set(CaptureRequest.COLOR_CORRECTION_MODE, whiteBalance.correctionMode);
        builder.set(CaptureRequest.COLOR_CORRECTION_GAINS, null);
        builder.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, null);
      }
      whiteBalance = null;
    }
    if (settings.containsKey("whiteBalanceWarmth")) {
      double warmth = number(settings.get("whiteBalanceWarmth"));
      checked(warmth, -1, 1, "whiteBalanceWarmth");
      if (!manualWhiteBalanceSupported(camera)) throw new IllegalArgumentException("Manual white balance is not supported");
      if (whiteBalance == null) whiteBalance = whiteBalanceBaseline(state);
      if (whiteBalance == null) throw new IllegalStateException("Camera has not reported its white balance calibration");
      builder.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF);
      if (Boolean.TRUE.equals(camera.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE))) builder.set(CaptureRequest.CONTROL_AWB_LOCK, false);
      builder.set(CaptureRequest.COLOR_CORRECTION_MODE, CaptureRequest.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX);
      builder.set(CaptureRequest.COLOR_CORRECTION_GAINS, warmthGains(whiteBalance.gains, warmth));
      // Android guarantees the copied HAL gains/transform preserve its prior
      // white point. Preserve the driver's sensor-to-sRGB calibration matrix.
      builder.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, whiteBalance.transform);
    }
    if (settings.containsKey("exposureMode")) {
      String mode = String.valueOf(settings.get("exposureMode"));
      if (!(mode.equals("auto") || mode.equals("manual"))) throw new IllegalArgumentException("Invalid exposure mode");
      if (mode.equals("manual") && !manualSupported(camera)) throw new IllegalArgumentException("Manual exposure is not supported");
      builder.set(CaptureRequest.CONTROL_AE_MODE, mode.equals("manual") ? CaptureRequest.CONTROL_AE_MODE_OFF : CaptureRequest.CONTROL_AE_MODE_ON);
      builder.set(CaptureRequest.CONTROL_AE_LOCK, false);
      if (mode.equals("auto")) {
        builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME, null);
        builder.set(CaptureRequest.SENSOR_SENSITIVITY, null);
        builder.set(CaptureRequest.SENSOR_FRAME_DURATION, null);
      }
    }
    boolean manual = Integer.valueOf(CaptureRequest.CONTROL_AE_MODE_OFF).equals(builder.get(CaptureRequest.CONTROL_AE_MODE));
    if (settings.containsKey("exposure")) {
      if (manual) throw new IllegalArgumentException("Exposure compensation requires automatic exposure");
      Range<Integer> range = camera.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE);
      double step = exposureStep(camera);
      if (range == null || step <= 0 || range.getUpper().equals(range.getLower())) throw new IllegalArgumentException("Exposure compensation is not supported");
      double ev = number(settings.get("exposure"));
      checked(ev, range.getLower() * step, range.getUpper() * step, "exposure");
      builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, (int)Math.round(ev / step));
    }
    if (settings.containsKey("exposureTimeMs") || settings.containsKey("iso")) {
      if (!manual || !manualSupported(camera)) throw new IllegalArgumentException("Manual exposure must be enabled first");
    }
    if (manual) {
      Range<Long> timeRange = camera.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE);
      Range<Integer> isoRange = camera.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE);
      double ms = settings.containsKey("exposureTimeMs") ? number(settings.get("exposureTimeMs")) :
          observedNumber(state, CaptureResult.SENSOR_EXPOSURE_TIME, builder.get(CaptureRequest.SENSOR_EXPOSURE_TIME), 10000000L) / 1e6;
      double iso = settings.containsKey("iso") ? number(settings.get("iso")) :
          observedNumber(state, CaptureResult.SENSOR_SENSITIVITY, builder.get(CaptureRequest.SENSOR_SENSITIVITY), isoRange.getLower());
      checked(ms, timeRange.getLower() / 1e6, timeRange.getUpper() / 1e6, "exposureTimeMs");
      checked(iso, isoRange.getLower(), isoRange.getUpper(), "iso");
      if (iso != Math.rint(iso)) throw new IllegalArgumentException("ISO must be an integer");
      long ns = Math.round(ms * 1e6);
      Long maxDuration = camera.get(CameraCharacteristics.SENSOR_INFO_MAX_FRAME_DURATION);
      long duration = Math.max(ns, 1000000000L / Math.max(1, view.format.framerate.max / view.fpsUnit));
      if (maxDuration != null && duration > maxDuration) duration = maxDuration;
      builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME, ns);
      builder.set(CaptureRequest.SENSOR_SENSITIVITY, (int)Math.round(iso));
      builder.set(CaptureRequest.SENSOR_FRAME_DURATION, duration);
    }
    return whiteBalance;
  }

  private Map<String, Object> snapshot(View view, State state) {
    CameraCharacteristics camera = view.characteristics;
    Map<String, Object> output = map("cameraId", view.cameraId, "ready", true, "native", true, "readback", state.observed != null);
    Range<Float> range = ratioRange(camera);
    double min = range == null ? 1 : range.getLower(), max = range == null ? maxDigitalZoom(camera) : range.getUpper();
    double zoom = 1;
    if (range != null) zoom = observedNumber(state, CaptureResult.CONTROL_ZOOM_RATIO, state.request.get(CaptureRequest.CONTROL_ZOOM_RATIO), 1f);
    else {
      Rect active = camera.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
      Rect selected = observed(state, CaptureResult.SCALER_CROP_REGION, state.request.get(CaptureRequest.SCALER_CROP_REGION));
      if (active != null && selected != null && selected.width() > 0) zoom = (double)active.width() / selected.width();
    }
    output.put("zoom", map("supported", max > min, "min", min, "max", max, "step", 0.0, "value", zoom,
        "native", true, "method", range == null ? "crop" : "ratio"));
    List<String> modes = whiteBalanceModes(camera);
    Integer awb = observed(state, CaptureResult.CONTROL_AWB_MODE, state.request.get(CaptureRequest.CONTROL_AWB_MODE));
    output.put("whiteBalance", map("supported", modes.size() > 1, "modes", modes, "value", awbName(awb == null ? CaptureRequest.CONTROL_AWB_MODE_AUTO : awb)));
    boolean warmthSupported = manualWhiteBalanceSupported(camera) &&
        (state.whiteBalance != null || whiteBalanceBaseline(state) != null);
    double warmth = observedWarmth(state);
    output.put("whiteBalanceWarmth", map("supported", warmthSupported, "min", -1.0, "max", 1.0,
        "step", 0.0, "value", warmth, "unit", "relative",
        "mode", awb != null && awb != CaptureRequest.CONTROL_AWB_MODE_AUTO ? "manual" : "auto"));
    Range<Integer> evRange = camera.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE);
    double step = exposureStep(camera);
    double ev = observedNumber(state, CaptureResult.CONTROL_AE_EXPOSURE_COMPENSATION, state.request.get(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION), 0) * step;
    boolean manual = Integer.valueOf(CaptureRequest.CONTROL_AE_MODE_OFF).equals(observed(state, CaptureResult.CONTROL_AE_MODE, state.request.get(CaptureRequest.CONTROL_AE_MODE)));
    output.put("exposure", map("supported", evRange != null && step > 0 && evRange.getUpper() > evRange.getLower(),
        "min", evRange == null ? 0 : evRange.getLower() * step, "max", evRange == null ? 0 : evRange.getUpper() * step,
        "step", step, "value", ev, "enabled", !manual));
    output.put("brightness", map("supported", false));
    if (manualSupported(camera)) {
      Range<Long> times = camera.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE);
      Range<Integer> isos = camera.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE);
      output.put("manualExposure", map("supported", true, "mode", manual ? "manual" : "auto",
          "timeMinMs", times.getLower() / 1e6, "timeMaxMs", times.getUpper() / 1e6,
          "timeMs", observedNumber(state, CaptureResult.SENSOR_EXPOSURE_TIME, state.request.get(CaptureRequest.SENSOR_EXPOSURE_TIME), times.getLower()) / 1e6,
          "isoMin", isos.getLower(), "isoMax", isos.getUpper(),
          "iso", (int)observedNumber(state, CaptureResult.SENSOR_SENSITIVITY, state.request.get(CaptureRequest.SENSOR_SENSITIVITY), isos.getLower())));
    } else output.put("manualExposure", map("supported", false, "mode", "auto"));
    Map<String, Object> observed = new HashMap<>();
    if (state.observed != null) {
      observed.put("frameNumber", state.observed.getFrameNumber());
      Float focal = state.observed.get(CaptureResult.LENS_FOCAL_LENGTH);
      if (focal != null) observed.put("focalLengthMm", focal.doubleValue());
      if (Build.VERSION.SDK_INT >= 30) {
        Float actualZoom = state.observed.get(CaptureResult.CONTROL_ZOOM_RATIO);
        if (actualZoom != null) { observed.put("zoom", actualZoom.doubleValue()); observed.put("zoomRatio", actualZoom.doubleValue()); }
      }
      Integer actualEv = state.observed.get(CaptureResult.CONTROL_AE_EXPOSURE_COMPENSATION);
      if (actualEv != null) observed.put("exposure", actualEv * step);
      Long actualTime = state.observed.get(CaptureResult.SENSOR_EXPOSURE_TIME);
      if (actualTime != null) observed.put("exposureTimeMs", actualTime / 1e6);
      Integer actualIso = state.observed.get(CaptureResult.SENSOR_SENSITIVITY);
      if (actualIso != null) observed.put("iso", actualIso);
      Integer actualAwb = state.observed.get(CaptureResult.CONTROL_AWB_MODE);
      if (actualAwb != null) { observed.put("whiteBalance", awbName(actualAwb)); observed.put("awbMode", actualAwb); }
      RggbChannelVector gains = state.observed.get(CaptureResult.COLOR_CORRECTION_GAINS);
      if (validGains(gains)) {
        observed.put("whiteBalanceGains", Arrays.asList((double)gains.getRed(), (double)gains.getGreenEven(),
            (double)gains.getGreenOdd(), (double)gains.getBlue()));
        if (state.whiteBalance != null && Integer.valueOf(CaptureRequest.CONTROL_AWB_MODE_OFF).equals(actualAwb))
          observed.put("whiteBalanceWarmth", warmth);
      }
      Integer colorMode = state.observed.get(CaptureResult.COLOR_CORRECTION_MODE);
      if (colorMode != null) observed.put("colorCorrectionMode", colorMode);
      ColorSpaceTransform transform = state.observed.get(CaptureResult.COLOR_CORRECTION_TRANSFORM);
      if (validTransform(transform)) {
        List<Double> matrix = new ArrayList<>();
        for (int row = 0; row < 3; ++row) for (int column = 0; column < 3; ++column)
          matrix.add(transform.getElement(column, row).doubleValue());
        observed.put("colorCorrectionTransform", matrix);
      }
      Integer actualAe = state.observed.get(CaptureResult.CONTROL_AE_MODE);
      if (actualAe != null) observed.put("aeMode", actualAe);
      if (Build.VERSION.SDK_INT >= 28) {
        String physical = state.observed.get(CaptureResult.LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID);
        if (physical != null) observed.put("activePhysicalId", physical);
      }
    }
    output.put("observed", observed);
    output.put("lenses", cameraSources(context));
    return output;
  }

  private static void applyLegacy(Camera camera, Map<String, Object> settings) {
    Camera.Parameters parameters = camera.getParameters();
    for (String key : settings.keySet()) if (!Arrays.asList("zoom", "whiteBalance", "exposure", "exposureMode").contains(key))
      throw new IllegalArgumentException("Unsupported camera setting: " + key);
    if (settings.containsKey("zoom")) {
      if (!parameters.isZoomSupported()) throw new IllegalArgumentException("Zoom is not supported");
      double ratio = number(settings.get("zoom"));
      List<Integer> ratios = parameters.getZoomRatios();
      checked(ratio, ratios.get(0) / 100.0, ratios.get(ratios.size() - 1) / 100.0, "zoom");
      int closest = 0;
      for (int i = 1; i < ratios.size(); ++i) if (Math.abs(ratios.get(i) / 100.0 - ratio) < Math.abs(ratios.get(closest) / 100.0 - ratio)) closest = i;
      parameters.setZoom(closest);
    }
    if (settings.containsKey("whiteBalance")) {
      Object value = settings.get("whiteBalance");
      if (!(value instanceof String) || parameters.getSupportedWhiteBalance() == null || !parameters.getSupportedWhiteBalance().contains(value))
        throw new IllegalArgumentException("White balance mode is not supported");
      parameters.setWhiteBalance((String)value);
    }
    if (settings.containsKey("exposureMode") && !"auto".equals(settings.get("exposureMode")))
      throw new IllegalArgumentException("Manual exposure is not supported");
    if (settings.containsKey("exposure")) {
      double step = parameters.getExposureCompensationStep(), ev = number(settings.get("exposure"));
      if (step <= 0 || parameters.getMinExposureCompensation() == parameters.getMaxExposureCompensation()) throw new IllegalArgumentException("Exposure compensation is not supported");
      checked(ev, parameters.getMinExposureCompensation() * step, parameters.getMaxExposureCompensation() * step, "exposure");
      parameters.setExposureCompensation((int)Math.round(ev / step));
      if (parameters.isAutoExposureLockSupported()) parameters.setAutoExposureLock(false);
    }
    camera.setParameters(parameters);
  }
  private Map<String, Object> snapshotLegacy(View view) {
    Camera.Parameters parameters = view.legacy.getParameters();
    List<Integer> ratios = parameters.isZoomSupported() ? parameters.getZoomRatios() : Collections.singletonList(100);
    List<String> modes = parameters.getSupportedWhiteBalance();
    double step = parameters.getExposureCompensationStep();
    return map("cameraId", view.cameraId, "ready", true, "native", true, "readback", true,
        "zoom", map("supported", ratios.size() > 1, "min", ratios.get(0) / 100.0, "max", ratios.get(ratios.size() - 1) / 100.0,
            "step", 0.0, "value", ratios.get(parameters.isZoomSupported() ? parameters.getZoom() : 0) / 100.0, "native", true, "method", "camera1"),
        "whiteBalance", map("supported", modes != null && modes.size() > 1, "modes", modes == null ? Collections.emptyList() : modes,
            "value", parameters.getWhiteBalance() == null ? "auto" : parameters.getWhiteBalance()),
        "exposure", map("supported", step > 0 && parameters.getMaxExposureCompensation() > parameters.getMinExposureCompensation(),
            "min", parameters.getMinExposureCompensation() * step, "max", parameters.getMaxExposureCompensation() * step,
            "step", step, "value", parameters.getExposureCompensation() * step, "enabled", true),
        "brightness", map("supported", false),
        "whiteBalanceWarmth", map("supported", false, "min", -1.0, "max", 1.0, "step", 0.0, "value", 0.0, "unit", "relative",
            "mode", "auto".equals(parameters.getWhiteBalance()) ? "auto" : "manual"),
        "manualExposure", map("supported", false, "mode", "auto"), "observed", Collections.emptyMap());
  }

  public static List<Map<String, Object>> cameraSources(Context context) {
    List<Map<String, Object>> output = new ArrayList<>();
    if (!Camera2Enumerator.isSupported(context)) {
      Camera1Enumerator enumerator = new Camera1Enumerator(false);
      for (String id : enumerator.getDeviceNames()) {
        boolean front = enumerator.isFrontFacing(id);
        output.add(map("id", id, "deviceId", id, "label", id, "frontFacing", front,
            "facing", front ? "front" : "back", "kind", "videoinput", "groupId", "camera"));
      }
      return output;
    }
    CameraManager manager = (CameraManager)context.getSystemService(Context.CAMERA_SERVICE);
    try {
      for (String id : manager.getCameraIdList()) {
        CameraCharacteristics camera = manager.getCameraCharacteristics(id);
        android.hardware.camera2.params.StreamConfigurationMap streams = camera.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        if (streams == null || streams.getOutputSizes(SurfaceTexture.class) == null || streams.getOutputSizes(SurfaceTexture.class).length == 0) continue;
        Integer facing = camera.get(CameraCharacteristics.LENS_FACING);
        boolean front = Integer.valueOf(CameraCharacteristics.LENS_FACING_FRONT).equals(facing);
        float[] focals = camera.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
        Float focal = focals != null && focals.length > 0 ? focals[0] : null;
        String label = (front ? "Front" : "Rear") + " camera " + id;
        if (focal != null) label += " (" + String.format(java.util.Locale.ROOT, "%.1f mm", focal) + ")";
        Map<String, Object> item = map("id", id, "deviceId", id, "label", label, "frontFacing", front,
            "facing", front ? "front" : "back", "kind", "videoinput", "groupId", "camera");
        if (focal != null) item.put("focalLengthMm", focal.doubleValue());
        if (Build.VERSION.SDK_INT >= 28) {
          item.put("logical", contains(camera.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES), CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA));
          item.put("physicalCameraIds", new ArrayList<>(camera.getPhysicalCameraIds()));
        }
        output.add(item);
      }
    } catch (CameraAccessException | RuntimeException error) {
      // Camera service can become unavailable while a device is being removed.
    }
    return output;
  }
  private static boolean manualSupported(CameraCharacteristics camera) {
    return contains(camera.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES), CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        && contains(camera.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES), CaptureRequest.CONTROL_AE_MODE_OFF)
        && camera.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE) != null
        && camera.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE) != null;
  }
  private static boolean manualWhiteBalanceSupported(CameraCharacteristics camera) {
    if (!contains(camera.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES), CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING)
        || !contains(camera.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES), CaptureRequest.CONTROL_AWB_MODE_OFF)) return false;
    List<CaptureRequest.Key<?>> requests = camera.getAvailableCaptureRequestKeys();
    List<CaptureResult.Key<?>> results = camera.getAvailableCaptureResultKeys();
    if (requests == null || results == null ||
        !requests.containsAll(Arrays.asList(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.COLOR_CORRECTION_MODE,
            CaptureRequest.COLOR_CORRECTION_GAINS, CaptureRequest.COLOR_CORRECTION_TRANSFORM)) ||
        !results.containsAll(Arrays.asList(CaptureResult.CONTROL_AWB_MODE, CaptureResult.COLOR_CORRECTION_MODE,
            CaptureResult.COLOR_CORRECTION_GAINS, CaptureResult.COLOR_CORRECTION_TRANSFORM))) return false;
    if (Build.VERSION.SDK_INT >= 36) {
      int[] modes = camera.get(CameraCharacteristics.COLOR_CORRECTION_AVAILABLE_MODES);
      if (modes != null && !contains(modes, CaptureRequest.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)) return false;
    }
    return true;
  }
  private static WhiteBalanceBaseline whiteBalanceBaseline(State state) {
    if (state.observed == null) return null;
    RggbChannelVector gains = state.observed.get(CaptureResult.COLOR_CORRECTION_GAINS);
    ColorSpaceTransform transform = state.observed.get(CaptureResult.COLOR_CORRECTION_TRANSFORM);
    Integer mode = state.observed.get(CaptureResult.COLOR_CORRECTION_MODE);
    if (!validGains(gains) || !validTransform(transform)) return null;
    // AWB overrides color-correction controls. Restore the driver's actual mode
    // even if it reports TRANSFORM_MATRIX; API36 can exclude FAST entirely.
    int automaticMode = mode != null ? mode : CaptureRequest.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX;
    return new WhiteBalanceBaseline(gains, transform, automaticMode);
  }
  /** Relative warm/cool axis around the frozen HAL white point; never Kelvin. */
  static RggbChannelVector warmthGains(RggbChannelVector baseline, double warmth) {
    if (!validGains(baseline) || !Double.isFinite(warmth) || warmth < -1 || warmth > 1)
      throw new IllegalArgumentException("White balance warmth is outside its range");
    double factor = Math.pow(2, warmth / 2);
    return new RggbChannelVector(boundedGain(baseline.getRed(), factor), baseline.getGreenEven(),
        baseline.getGreenOdd(), boundedGain(baseline.getBlue(), 1 / factor));
  }
  private static float boundedGain(float baseline, double factor) {
    // [1,3] is guaranteed by Camera2. A driver's own baseline can lie outside
    // that range; retain its existing extreme rather than changing neutral or
    // extending it farther into an undocumented gain range.
    return (float)Math.max(Math.min(1, baseline), Math.min(Math.max(3, baseline), baseline * factor));
  }
  private static boolean validGains(RggbChannelVector gains) {
    return gains != null && positive(gains.getRed()) && positive(gains.getGreenEven()) &&
        positive(gains.getGreenOdd()) && positive(gains.getBlue());
  }
  private static boolean positive(float value) { return Float.isFinite(value) && value > 0; }
  private static boolean validTransform(ColorSpaceTransform transform) {
    if (transform == null) return false;
    for (int row = 0; row < 3; ++row) for (int column = 0; column < 3; ++column)
      if (!Double.isFinite(transform.getElement(column, row).doubleValue())) return false;
    return true;
  }
  private static double observedWarmth(State state) {
    if (state.whiteBalance == null || state.observed == null ||
        !Integer.valueOf(CaptureRequest.CONTROL_AWB_MODE_OFF).equals(state.observed.get(CaptureResult.CONTROL_AWB_MODE))) return 0;
    RggbChannelVector actual = state.observed.get(CaptureResult.COLOR_CORRECTION_GAINS);
    if (!validGains(actual)) return 0;
    double ratio = (actual.getRed() / actual.getBlue()) /
        (state.whiteBalance.gains.getRed() / state.whiteBalance.gains.getBlue());
    return Math.max(-1, Math.min(1, Math.log(ratio) / Math.log(2)));
  }
  private static Range<Float> ratioRange(CameraCharacteristics camera) {
    return Build.VERSION.SDK_INT >= 30 ? camera.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) : null;
  }
  private static double maxDigitalZoom(CameraCharacteristics camera) {
    Float max = camera.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM);
    return max != null && Float.isFinite(max) ? Math.max(1, max) : 1;
  }
  private static double exposureStep(CameraCharacteristics camera) {
    Rational value = camera.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP);
    return value == null ? 0 : value.doubleValue();
  }
  static Rect crop(Rect active, double ratio) {
    if (active == null || ratio < 1 || !Double.isFinite(ratio)) throw new IllegalArgumentException("Camera crop is unavailable");
    int width = Math.max(1, (int)Math.round(active.width() / ratio));
    int height = Math.max(1, (int)Math.round(active.height() / ratio));
    int left = active.left + (active.width() - width) / 2, top = active.top + (active.height() - height) / 2;
    return new Rect(left, top, left + width, top + height);
  }
  private static final String[] AWB_NAMES = {"off", "auto", "incandescent", "fluorescent", "warm-fluorescent", "daylight", "cloudy-daylight", "twilight", "shade"};
  private static String awbName(int value) { return value >= 0 && value < AWB_NAMES.length ? AWB_NAMES[value] : "auto"; }
  private static int awbValue(String value) { return Arrays.asList(AWB_NAMES).indexOf(value); }
  private static List<String> whiteBalanceModes(CameraCharacteristics camera) {
    List<String> output = new ArrayList<>();
    int[] modes = camera.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES);
    if (modes != null) for (int mode : modes) if (mode > 0 && mode < AWB_NAMES.length) output.add(awbName(mode));
    return output;
  }
  private static boolean contains(int[] values, int value) {
    if (values != null) for (int item : values) if (item == value) return true;
    return false;
  }
  private static double number(Object value) {
    if (!(value instanceof Number) || !Double.isFinite(((Number)value).doubleValue())) throw new IllegalArgumentException("Camera value must be finite");
    return ((Number)value).doubleValue();
  }
  private static void checked(double value, double min, double max, String name) {
    if (value < min - 1e-7 || value > max + 1e-7) throw new IllegalArgumentException(name + " is outside the device range");
  }
  private static <T> T observed(State state, CaptureResult.Key<T> key, T fallback) {
    T value = state.observed == null ? null : state.observed.get(key);
    return value == null ? fallback : value;
  }
  private static double observedNumber(State state, CaptureResult.Key<? extends Number> key, Number request, Number fallback) {
    Number value = state.observed == null ? null : state.observed.get(key);
    return (value != null ? value : request != null ? request : fallback).doubleValue();
  }
  private static Map<String, Object> map(Object... pairs) {
    Map<String, Object> output = new LinkedHashMap<>();
    for (int i = 0; i < pairs.length; i += 2) output.put((String)pairs[i], pairs[i + 1]);
    return output;
  }
  static Object field(Object target, String name) throws ReflectiveOperationException {
    if (target == null) throw new IllegalStateException("Camera session has closed");
    for (Class<?> type = target.getClass(); type != null; type = type.getSuperclass()) {
      try {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(target);
      } catch (NoSuchFieldException ignored) { }
    }
    throw new NoSuchFieldException(name);
  }
}
