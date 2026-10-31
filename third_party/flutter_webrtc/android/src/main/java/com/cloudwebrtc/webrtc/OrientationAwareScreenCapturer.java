package com.cloudwebrtc.webrtc;

import org.webrtc.SurfaceTextureHelper;
import org.webrtc.CapturerObserver;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoCapturer;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;

import com.cloudwebrtc.webrtc.utils.EglUtils;

import android.annotation.TargetApi;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;
import android.view.WindowManager;
import android.app.Activity;
import android.hardware.display.DisplayManager;
import android.util.DisplayMetrics;
import android.util.Log;
import android.hardware.display.VirtualDisplay;
import android.media.projection.MediaProjectionManager;
import android.view.Display;

/**
 * An copy of ScreenCapturerAndroid to capture the screen content while being aware of device orientation
 */
@TargetApi(21)
public class OrientationAwareScreenCapturer implements VideoCapturer, VideoSink {
    private static final String TAG = "OrientationAwareSC";
    private static final int DISPLAY_FLAGS =
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC | DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION;
    // DPI for VirtualDisplay, does not seem to matter for us.
    private static final int VIRTUAL_DISPLAY_DPI = 400;
    private final Intent mediaProjectionPermissionResultData;
    private final MediaProjection.Callback externalMediaProjectionCallback;
    private final MediaProjection.Callback mediaProjectionCallback;
    private final int maxShortSide;
    private int width;
    private int height;
    private int oldWidth;
    private int oldHeight;
    private VirtualDisplay virtualDisplay;
    private Surface virtualDisplaySurface;
    private volatile SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private long numCapturedFrames = 0;
    private MediaProjection mediaProjection;
    private volatile boolean isDisposed = false;
    private volatile boolean captureStarted = false;
    private MediaProjectionManager mediaProjectionManager;
    private WindowManager windowManager;
    private boolean resizePending = false;
    private volatile boolean usesCapturedContentResize = false;
    private int pendingWidth;
    private int pendingHeight;
    private int activeStopCalls;
    private final Runnable resizeTask = this::applyPendingCaptureFormat;
    private static final long STATIC_FRAME_INTERVAL_MS = 1000;
    private final Runnable staticFrameTask = this::refreshStaticFrame;
    private volatile boolean hasCapturedFrame;
    private volatile long lastFrameTimeMs;
    private volatile long lastFrameTimestampNs;
    private volatile long lastFrameDeliveryTimeNs;

    /**
     * Constructs a new Screen Capturer.
     *
     * @param mediaProjectionPermissionResultData the result data of MediaProjection permission
     *                                            activity; the calling app must validate that result code is Activity.RESULT_OK before
     *                                            calling this method.
     * @param mediaProjectionCallback             MediaProjection callback to implement application specific
     *                                            logic in events such as when the user revokes a previously granted capture permission.
     **/
    public OrientationAwareScreenCapturer(Intent mediaProjectionPermissionResultData,
                                          MediaProjection.Callback mediaProjectionCallback) {
        this(mediaProjectionPermissionResultData, mediaProjectionCallback, 0);
    }

    public OrientationAwareScreenCapturer(Intent mediaProjectionPermissionResultData,
                                          MediaProjection.Callback mediaProjectionCallback,
                                          int maxShortSide) {
        this.maxShortSide = Math.max(0, maxShortSide);
        this.mediaProjectionPermissionResultData = mediaProjectionPermissionResultData;
        this.externalMediaProjectionCallback = mediaProjectionCallback;
        this.mediaProjectionCallback = new MediaProjection.Callback() {
            @Override
            public void onStop() {
                dispose();
                if (externalMediaProjectionCallback != null) {
                    externalMediaProjectionCallback.onStop();
                }
            }

            @Override
            public void onCapturedContentResize(int width, int height) {
                if (width <= 0 || height <= 0) {
                    return;
                }
                usesCapturedContentResize = true;
                Log.d(TAG, "Captured content resized to " + width + "x" + height);
                requestCaptureFormat(width, height);
            }
        };
    }

    public void onFrame(VideoFrame frame) {
        if (isDisposed || !captureStarted) {
            return;
        }
        numCapturedFrames++;
        final long nowNs = System.nanoTime();
        final long elapsedNs = Math.max(1, nowNs - lastFrameDeliveryTimeNs);
        lastFrameDeliveryTimeNs = nowNs;
        hasCapturedFrame = true;
        lastFrameTimeMs = SystemClock.uptimeMillis();
        maybeUpdateCaptureFormatFromDisplay();
        // forceFrame() reuses the SurfaceTexture timestamp. WebRTC discards
        // duplicates, so a replay needs a fresh monotonic timestamp. Preserve
        // normal source timestamps while they continue to advance.
        if (frame.getTimestampNs() > lastFrameTimestampNs) {
            lastFrameTimestampNs = frame.getTimestampNs();
            capturerObserver.onFrameCaptured(frame);
        } else {
            // Preserve the source clock domain: its timestamps may include
            // suspend time and therefore be ahead of System.nanoTime().
            lastFrameTimestampNs += elapsedNs;
            frame.getBuffer().retain();
            final VideoFrame refreshed = new VideoFrame(
                    frame.getBuffer(), frame.getRotation(), lastFrameTimestampNs);
            try {
                capturerObserver.onFrameCaptured(refreshed);
            } finally {
                refreshed.release();
            }
        }
    }

    private synchronized void refreshStaticFrame() {
        final SurfaceTextureHelper helper = surfaceTextureHelper;
        if (isDisposed || !captureStarted || helper == null) {
            return;
        }
        // VirtualDisplay emits only changed content. A viewer joining an idle
        // screen otherwise has no frame to encode until the user touches it.
        // Reuse the current texture at most once per second, never before its
        // first valid frame and never while real frames are arriving.
        if (hasCapturedFrame && SystemClock.uptimeMillis() - lastFrameTimeMs >= STATIC_FRAME_INTERVAL_MS) {
            helper.forceFrame();
        }
        scheduleStaticFrame(helper);
    }

    private void scheduleStaticFrame(final SurfaceTextureHelper helper) {
        helper.getHandler().removeCallbacks(staticFrameTask);
        helper.getHandler().postDelayed(staticFrameTask, STATIC_FRAME_INTERVAL_MS);
    }

    private DisplayMetrics currentDisplayMetrics() {
        final Display display = windowManager.getDefaultDisplay();
        final DisplayMetrics metrics = new DisplayMetrics();
        display.getRealMetrics(metrics);
        return metrics;
    }

    private void maybeUpdateCaptureFormatFromDisplay() {
        if (usesCapturedContentResize) {
            return;
        }
        // Poll lightly from the capture callback. Android rotation changes the
        // real display size, and the VirtualDisplay must follow it or the
        // encoded frames are squeezed on the receiver.
        if (numCapturedFrames % 4 != 0 || windowManager == null || surfaceTextureHelper == null) {
            return;
        }
        final DisplayMetrics metrics = currentDisplayMetrics();
        requestCaptureFormat(metrics.widthPixels, metrics.heightPixels);
    }

    private void checkNotDisposed() {
        if (isDisposed) {
            throw new RuntimeException("capturer is disposed.");
        }
    }

    public synchronized void initialize(final SurfaceTextureHelper surfaceTextureHelper,
                                        final Context applicationContext, final CapturerObserver capturerObserver) {
        checkNotDisposed();
        if (capturerObserver == null) {
            throw new RuntimeException("capturerObserver not set.");
        }
        this.capturerObserver = capturerObserver;
        if (surfaceTextureHelper == null) {
            throw new RuntimeException("surfaceTextureHelper not set.");
        }
        this.surfaceTextureHelper = surfaceTextureHelper;

        this.windowManager = (WindowManager) applicationContext.getSystemService(
                Context.WINDOW_SERVICE);
        this.mediaProjectionManager = (MediaProjectionManager) applicationContext.getSystemService(
                Context.MEDIA_PROJECTION_SERVICE);
    }

    @Override
    public synchronized void startCapture(
            final int width, final int height, final int ignoredFramerate) {
        checkNotDisposed();
        if (captureStarted) {
            return;
        }
        if (activeStopCalls != 0) {
            throw new IllegalStateException("capturer is stopping.");
        }

        final DisplayMetrics metrics = currentDisplayMetrics();
        final int sourceWidth = metrics.widthPixels > 0 ? metrics.widthPixels : width;
        final int sourceHeight = metrics.heightPixels > 0 ? metrics.heightPixels : height;
        final double scale = captureScale(sourceWidth, sourceHeight);
        this.width = scaledDimension(sourceWidth, scale);
        this.height = scaledDimension(sourceHeight, scale);
        this.oldWidth = this.width;
        this.oldHeight = this.height;
        usesCapturedContentResize = false;

        mediaProjection = mediaProjectionManager.getMediaProjection(
                Activity.RESULT_OK, mediaProjectionPermissionResultData);

        // Capture helpers are replaced on rotation. Keep projection callbacks
        // on a stable handler so revocation cannot be lost when a helper quits.
        mediaProjection.registerCallback(mediaProjectionCallback, new Handler(Looper.getMainLooper()));

        createVirtualDisplay();
        captureStarted = true;
        hasCapturedFrame = false;
        lastFrameTimeMs = 0;
        capturerObserver.onCapturerStarted(true);
        surfaceTextureHelper.startListening(this);
        scheduleStaticFrame(surfaceTextureHelper);
    }

    synchronized MediaProjection getMediaProjection() {
        if (!captureStarted || mediaProjection == null) {
            throw new IllegalStateException("Screen projection is not active");
        }
        return mediaProjection;
    }

    @Override
    public void stopCapture() {
        stopCapture(false);
    }

    private void stopCapture(final boolean disposing) {
        final SurfaceTextureHelper helper = retainStopHelper(disposing);
        if (helper == null) {
            return;
        }
        try {
            stopCaptureOnHelper(helper);
        } finally {
            releaseStopHelper(helper);
        }
    }

    private synchronized SurfaceTextureHelper retainStopHelper(final boolean disposing) {
        if (isDisposed) {
            return null;
        }
        if (disposing) {
            isDisposed = true;
        }
        captureStarted = false;
        // Resize hands off ownership under this same monitor. Retain the
        // selected helper until every concurrent stop has finished using it.
        final SurfaceTextureHelper helper = surfaceTextureHelper;
        if (helper != null) {
            activeStopCalls++;
        }
        return helper;
    }

    private void releaseStopHelper(final SurfaceTextureHelper helper) {
        boolean disposeHelper = false;
        synchronized (this) {
            activeStopCalls--;
            if (isDisposed && activeStopCalls == 0 && surfaceTextureHelper == helper) {
                surfaceTextureHelper = null;
                disposeHelper = true;
            }
        }
        if (disposeHelper) {
            // Release EGL/thread after pending stop calls and texture frames.
            helper.dispose();
        }
    }

    private void stopCaptureOnHelper(final SurfaceTextureHelper helper) {
        // Do not hold this capturer's monitor while waiting for the capture
        // thread: a queued resize also needs that monitor.
        ThreadUtils.invokeAtFrontUninterruptibly(helper.getHandler(), new Runnable() {
            @Override
            public void run() {
                helper.getHandler().removeCallbacks(resizeTask);
                helper.getHandler().removeCallbacks(staticFrameTask);
                hasCapturedFrame = false;
                resizePending = false;
                helper.stopListening();
                if (virtualDisplay != null || mediaProjection != null) {
                    capturerObserver.onCapturerStopped();
                }
                if (virtualDisplay != null) {
                    virtualDisplay.release();
                    virtualDisplay = null;
                }
                releaseVirtualDisplaySurface();
                if (mediaProjection != null) {
                    // Unregister the callback before stopping, otherwise the callback recursively
                    // calls this method.
                    mediaProjection.unregisterCallback(mediaProjectionCallback);
                    mediaProjection.stop();
                    mediaProjection = null;
                }
            }
        });
    }

    @Override
    public void dispose() {
        stopCapture(true);
    }

    /**
     * Changes output video format. This method can be used to scale the output
     * video, or to change orientation when the captured screen is rotated for example.
     *
     * @param width            new output video width
     * @param height           new output video height
     * @param ignoredFramerate ignored
     */
    @Override
    public synchronized void changeCaptureFormat(
            final int width, final int height, final int ignoredFramerate) {
        checkNotDisposed();
        requestCaptureFormat(width, height);
    }

    private synchronized void requestCaptureFormat(final int nextWidth, final int nextHeight) {
        if (isDisposed || !captureStarted || nextWidth <= 0 || nextHeight <= 0 || surfaceTextureHelper == null) {
            return;
        }
        final double scale = captureScale(nextWidth, nextHeight);
        pendingWidth = scaledDimension(nextWidth, scale);
        pendingHeight = scaledDimension(nextHeight, scale);
        if (resizePending || (this.oldWidth == pendingWidth && this.oldHeight == pendingHeight)) {
            return;
        }
        resizePending = true;
        if (!surfaceTextureHelper.getHandler().post(resizeTask)) {
            resizePending = false;
        }
    }

    private double captureScale(int width, int height) {
        if (maxShortSide == 0 || width <= 0 || height <= 0) return 1.0;
        return Math.min(1.0, (double) maxShortSide / Math.min(width, height));
    }

    private static int scaledDimension(int size, double scale) {
        // Even dimensions work with hardware H264 encoders. Avoid upscaling.
        return scale >= 1.0 ? size : Math.max(2, ((int) (size * scale) / 2) * 2);
    }

    private synchronized void applyPendingCaptureFormat() {
        try {
            if (isDisposed || !captureStarted || surfaceTextureHelper == null || mediaProjection == null) {
                resizePending = false;
                return;
            }
            if (this.oldWidth == pendingWidth && this.oldHeight == pendingHeight) {
                resizePending = false;
                return;
            }
            this.width = pendingWidth;
            this.height = pendingHeight;
            resizeVirtualDisplay();
            this.oldWidth = pendingWidth;
            this.oldHeight = pendingHeight;
            Log.d(TAG, "Screen capture resized to " + width + "x" + height);
        } catch (Throwable error) {
            this.width = this.oldWidth;
            this.height = this.oldHeight;
            Log.w(TAG, "Screen capture resize failed", error);
        } finally {
            resizePending = false;
        }
    }

    private void createVirtualDisplay() {
        hasCapturedFrame = false;
        updateSurfaceTextureSize();
        releaseVirtualDisplaySurface();
        virtualDisplaySurface = new Surface(surfaceTextureHelper.getSurfaceTexture());
        virtualDisplay = mediaProjection.createVirtualDisplay("WebRTC_ScreenCapture", width, height,
                VIRTUAL_DISPLAY_DPI, DISPLAY_FLAGS, virtualDisplaySurface,
                null /* callback */, null /* callback handler */);
    }

    private void resizeVirtualDisplay() {
        if (virtualDisplay != null && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            // WebRTC recreates VirtualDisplay before Android 12 because resize
            // can scale the screen incorrectly on those releases.
            virtualDisplay.release();
            virtualDisplay = null;
            createVirtualDisplay();
        } else if (virtualDisplay != null) {
            // Android can keep the old EGL output dimensions when the same
            // BufferQueue producer is resized. A new Surface wrapper around
            // the old SurfaceTexture does not change that producer. Replace
            // the texture/helper while retaining the single VirtualDisplay.
            final SurfaceTextureHelper oldHelper = surfaceTextureHelper;
            final Surface oldSurface = virtualDisplaySurface;
            final boolean oldHasCapturedFrame = hasCapturedFrame;
            final SurfaceTextureHelper resizedHelper = SurfaceTextureHelper.create(
                    "texture_screen_thread", EglUtils.getRootEglBaseContext());
            if (resizedHelper == null) {
                throw new IllegalStateException("Cannot create resized screen capture texture");
            }
            Surface resizedSurface = null;
            boolean listenerStopped = false;
            try {
                resizedHelper.setTextureSize(width, height);
                resizedSurface = new Surface(resizedHelper.getSurfaceTexture());
                oldHelper.getHandler().removeCallbacks(staticFrameTask);
                oldHelper.stopListening();
                listenerStopped = true;
                virtualDisplay.resize(width, height, VIRTUAL_DISPLAY_DPI);
                virtualDisplay.setSurface(resizedSurface);
                surfaceTextureHelper = resizedHelper;
                virtualDisplaySurface = resizedSurface;
                hasCapturedFrame = false;
                resizedHelper.startListening(this);
                scheduleStaticFrame(resizedHelper);
            } catch (RuntimeException error) {
                surfaceTextureHelper = oldHelper;
                virtualDisplaySurface = oldSurface;
                hasCapturedFrame = oldHasCapturedFrame;
                try {
                    virtualDisplay.resize(oldWidth, oldHeight, VIRTUAL_DISPLAY_DPI);
                    virtualDisplay.setSurface(oldSurface);
                    if (listenerStopped) {
                        oldHelper.startListening(this);
                    }
                    scheduleStaticFrame(oldHelper);
                } catch (RuntimeException rollbackError) {
                    error.addSuppressed(rollbackError);
                }
                if (resizedSurface != null) {
                    resizedSurface.release();
                }
                resizedHelper.dispose();
                throw error;
            }
            if (oldSurface != null) {
                oldSurface.release();
            }
            oldHelper.dispose();
        } else {
            hasCapturedFrame = false;
            updateSurfaceTextureSize();
            releaseVirtualDisplaySurface();
            virtualDisplaySurface = new Surface(surfaceTextureHelper.getSurfaceTexture());
            virtualDisplay = mediaProjection.createVirtualDisplay("WebRTC_ScreenCapture", width, height,
                    VIRTUAL_DISPLAY_DPI, DISPLAY_FLAGS, virtualDisplaySurface,
                    null /* callback */, null /* callback handler */);
        }
    }

    private void updateSurfaceTextureSize() {
        surfaceTextureHelper.setTextureSize(width, height);
        surfaceTextureHelper.getSurfaceTexture().setDefaultBufferSize(width, height);
    }

    private void releaseVirtualDisplaySurface() {
        if (virtualDisplaySurface != null) {
            virtualDisplaySurface.release();
            virtualDisplaySurface = null;
        }
    }

    @Override
    public boolean isScreencast() {
        return true;
    }

    public long getNumCapturedFrames() {
        return numCapturedFrames;
    }
}
