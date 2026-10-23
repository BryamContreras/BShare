#!/usr/bin/env python3
"""Compile the production track-removal method with small ownership doubles.

The method is copied unchanged into the host harness; Android integration and
SurfaceTexture thread shutdown are checked separately on the device.
"""

from pathlib import Path
import subprocess
import tempfile


def production_method(source, signature):
    start = source.index(signature)
    cursor = source.index("{", start)
    depth = 1
    end = cursor + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = """
import java.util.LinkedHashMap;
import java.util.Map;

public class VideoCapturerDisposalTest {
  static final String TAG = "test";
  final Map<String, VideoCapturerInfoEx> mVideoCapturers = new LinkedHashMap<>();
  final Map<String, SurfaceTextureHelper> mSurfaceTextureHelpers = new LinkedHashMap<>();
  final Context applicationContext = new Context();
  int errors;
  static class Result {}
  void resultError(String operation, String message, Result result) { ++errors; }
  static class Context {
    static final String WINDOW_SERVICE = "window";
    Object getSystemService(String name) { return new WindowManager(); }
  }
  static class WindowManager { Display getDefaultDisplay() { return new Display(); } }
  static class Display { void getRealSize(Point point) { point.x = 1080; point.y = 2400; } }
  static class Point { int x, y; }
  static class EglUtils { static Object getRootEglBaseContext() { return new Object(); } }
  static class CapturerObserver {}
  static class VideoTrack {}
  static class PeerConnectionFactory {
    boolean throwTrack, nullTrack;
    VideoTrack createVideoTrack(String id, VideoSource source) {
      if (throwTrack) throw new IllegalStateException("test track creation failure");
      return nullTrack ? null : new VideoTrack();
    }
  }
  static class Log {
    static void d(String tag, String message) {}
    static void e(String tag, String message) {}
    static void e(String tag, String message, Throwable error) {}
  }
  static class VideoSource {
    int disposals;
    boolean noObserver;
    static class AspectRatio { AspectRatio(int width, int height) {} }
    void adaptOutputFormat(AspectRatio landscape, Integer maxLandscapePixels,
        AspectRatio portrait, Integer maxPortraitPixels, Integer fps) {
      assert maxLandscapePixels == null && maxPortraitPixels == null;
    }
    CapturerObserver getCapturerObserver() { return noObserver ? null : new CapturerObserver(); }
    void dispose() { ++disposals; }
  }
  static class SurfaceTextureHelper {
    static final java.util.List<SurfaceTextureHelper> helpers = new java.util.ArrayList<>();
    static boolean failCreate, throwCreate;
    int stops, disposals;
    SurfaceTextureHelper() { helpers.add(this); }
    static SurfaceTextureHelper create(String name, Object context) {
      if (throwCreate) throw new IllegalStateException("test create failure");
      return failCreate ? null : new SurfaceTextureHelper();
    }
    void stopListening() { ++stops; }
    void dispose() { ++disposals; }
  }
  static class Capturer {
    int stops, disposals;
    boolean interruptStop, failDispose, failInitialize, failStart;
    SurfaceTextureHelper ownedHelper;
    void initialize(SurfaceTextureHelper helper, Context context, CapturerObserver observer) {
      ownedHelper = helper;
      if (failInitialize) throw new IllegalStateException("test initialize failure");
    }
    void startCapture(int width, int height, int fps) {
      if (failStart) throw new IllegalStateException("test start failure");
    }
    void stopCapture() throws InterruptedException {
      ++stops;
      if (interruptStop) throw new InterruptedException("test");
    }
    void dispose() {
      ++disposals;
      if (ownedHelper != null) { ownedHelper.stopListening(); ownedHelper.dispose(); ownedHelper = null; }
      if (failDispose) throw new IllegalStateException("test");
    }
  }
  static class CameraEventsHandler { void waitForCameraClosed() {} }
  static class VideoCapturerInfoEx {
    int width, height, fps;
    String primaryTrackId;
    Capturer capturer;
    CameraEventsHandler cameraEventsHandler;
    VideoSource videoSource;
  }
  // PRODUCTION_METHOD
  // STARTUP_METHOD
  void checkTrackCreation(PeerConnectionFactory pcFactory, String trackId,
      VideoSource videoSource, Result result) {
    VideoTrack displayTrack;
    // TRACK_CREATION_GUARD
  }
  VideoCapturerInfoEx addPrimary(String id, boolean camera) {
    VideoCapturerInfoEx info = new VideoCapturerInfoEx();
    info.capturer = new Capturer();
    info.videoSource = new VideoSource();
    mVideoCapturers.put(id, info);
    if (camera) mSurfaceTextureHelpers.put(id, new SurfaceTextureHelper());
    return info;
  }
  VideoCapturerInfoEx addShared(String id, String primary) {
    VideoCapturerInfoEx info = new VideoCapturerInfoEx();
    info.primaryTrackId = primary;
    info.videoSource = mVideoCapturers.get(primary).videoSource;
    mVideoCapturers.put(id, info);
    return info;
  }
  static void checkLastTrack(boolean camera, boolean interrupt, boolean failDispose) {
    VideoCapturerDisposalTest fixture = new VideoCapturerDisposalTest();
    VideoCapturerInfoEx info = fixture.addPrimary("primary", camera);
    Capturer capturer = info.capturer;
    VideoSource source = info.videoSource;
    SurfaceTextureHelper helper = fixture.mSurfaceTextureHelpers.get("primary");
    capturer.interruptStop = interrupt;
    capturer.failDispose = failDispose;
    try {
      fixture.removeVideoCapturer("primary");
      assert !failDispose;
    } catch (IllegalStateException expected) { assert failDispose; }
    assert capturer.stops == 1 && capturer.disposals == 1;
    assert source.disposals == 1 && info.videoSource == null;
    assert fixture.mVideoCapturers.isEmpty();
    assert fixture.mSurfaceTextureHelpers.isEmpty();
    if (camera) assert helper.stops == 1 && helper.disposals == 1;
    assert Thread.interrupted() == interrupt : "Interrupted status was not preserved";
    fixture.removeVideoCapturer("primary");
    assert capturer.disposals == 1 && source.disposals == 1;
  }
  public static void main(String[] args) {
    for (boolean throwsTrack : new boolean[] {false, true}) {
      for (boolean throwsCleanup : new boolean[] {false, true}) {
        VideoCapturerDisposalTest trackFailure = new VideoCapturerDisposalTest();
        VideoCapturerInfoEx info = trackFailure.addPrimary("screen", false);
        Capturer capturer = info.capturer;
        VideoSource source = info.videoSource;
        SurfaceTextureHelper helper = capturer.ownedHelper = new SurfaceTextureHelper();
        capturer.failDispose = throwsCleanup;
        PeerConnectionFactory factory = new PeerConnectionFactory();
        factory.throwTrack = throwsTrack;
        factory.nullTrack = !throwsTrack;
        trackFailure.checkTrackCreation(factory, "screen", source, new Result());
        assert trackFailure.errors == 1;
        assert capturer.stops == 1 && capturer.disposals == 1;
        assert source.disposals == 1 && helper.disposals == 1;
        assert trackFailure.mVideoCapturers.isEmpty();
      }
    }
    for (int mode = 0; mode < 6; ++mode) {
      VideoCapturerDisposalTest startup = new VideoCapturerDisposalTest();
      VideoCapturerInfoEx info = new VideoCapturerInfoEx();
      Capturer capturer = info.capturer = new Capturer();
      VideoSource source = info.videoSource = new VideoSource();
      SurfaceTextureHelper.helpers.clear();
      SurfaceTextureHelper.failCreate = mode == 0;
      SurfaceTextureHelper.throwCreate = mode == 1;
      capturer.failInitialize = mode == 2;
      capturer.failStart = mode == 3 || mode == 4;
      capturer.failDispose = mode == 4;
      source.noObserver = mode == 5;
      assert !startup.startScreenCapture(info, new Result());
      assert startup.errors == 1;
      assert capturer.disposals == 1 && source.disposals == 1 && info.videoSource == null;
      for (SurfaceTextureHelper helper : SurfaceTextureHelper.helpers) assert helper.disposals == 1;
    }
    SurfaceTextureHelper.failCreate = false;
    SurfaceTextureHelper.throwCreate = false;
    for (boolean camera : new boolean[] {false, true}) {
      checkLastTrack(camera, false, false);
      checkLastTrack(camera, true, false);
      checkLastTrack(camera, false, true);
    }
    VideoCapturerDisposalTest f = new VideoCapturerDisposalTest();
    VideoCapturerInfoEx primary = f.addPrimary("primary", true);
    Capturer capturer = primary.capturer;
    VideoSource source = primary.videoSource;
    SurfaceTextureHelper helper = f.mSurfaceTextureHelpers.get("primary");
    f.addShared("remove-secondary", "primary");
    f.addShared("promoted", "primary");
    VideoCapturerInfoEx last = f.addShared("last", "primary");
    f.removeVideoCapturer("remove-secondary");
    assert source.disposals == 0 && capturer.stops == 0;
    f.removeVideoCapturer("primary");
    VideoCapturerInfoEx promoted = f.mVideoCapturers.get("promoted");
    assert promoted.primaryTrackId == null && promoted.capturer == capturer;
    assert promoted.videoSource == source;
    assert last.primaryTrackId.equals("promoted");
    assert f.mSurfaceTextureHelpers.get("promoted") == helper;
    assert source.disposals == 0 && helper.disposals == 0;
    f.removeVideoCapturer("promoted");
    assert last.primaryTrackId == null && last.videoSource == source;
    assert source.disposals == 0;
    f.removeVideoCapturer("last");
    assert capturer.stops == 1 && capturer.disposals == 1;
    assert source.disposals == 1 && helper.disposals == 1;
    assert f.mVideoCapturers.isEmpty() && f.mSurfaceTextureHelpers.isEmpty();
    System.out.println("Video capturer startup/disposal: failed track/texture creation, initialization/start, "
        + "shared ownership, final release, interruption and disposal failure passed.");
  }
}
"""


def main():
    plugin = Path(__file__).resolve().parents[2]
    source = plugin / "android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java"
    contents = source.read_text()
    harness = HARNESS.replace("  // PRODUCTION_METHOD", production_method(
        contents, "    void removeVideoCapturer(String id) {"))
    harness = harness.replace("  // STARTUP_METHOD", production_method(
        contents, "    private boolean startScreenCapture("))
    guard_start = contents.index("        try {\n            displayTrack = pcFactory.createVideoTrack")
    guard_end = contents.index("        ConstraintsArray audioTracks", guard_start)
    harness = harness.replace("    // TRACK_CREATION_GUARD", contents[guard_start:guard_end])
    with tempfile.TemporaryDirectory(prefix="bshare-capturer-disposal-") as temporary:
        java = Path(temporary) / "VideoCapturerDisposalTest.java"
        java.write_text(harness)
        subprocess.run(["javac", "-d", temporary, str(java)], check=True)
        subprocess.run(["java", "-ea", "-cp", temporary, "VideoCapturerDisposalTest"], check=True)


if __name__ == "__main__":
    main()
