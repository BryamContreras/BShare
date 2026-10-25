#!/usr/bin/env python3
"""Exercise the real Android capturer's lifecycle with host Java API doubles.

This checks scheduling and resource ownership. Device capture/codec output still
requires an Android device; these doubles do not emulate its graphics stack.
"""

from pathlib import Path
import subprocess
import tempfile


STUBS = {
    "android/annotation/TargetApi.java": """
package android.annotation;
public @interface TargetApi { int value(); }
""",
    "android/app/Activity.java": """
package android.app;
public class Activity { public static final int RESULT_OK = -1; }
""",
    "android/content/Intent.java": "package android.content; public class Intent {}",
    "android/content/Context.java": """
package android.content;
public class Context {
  public static final String WINDOW_SERVICE = "window";
  public static final String MEDIA_PROJECTION_SERVICE = "projection";
  public final android.view.WindowManager windows = new android.view.WindowManager();
  public final android.media.projection.MediaProjectionManager projections =
      new android.media.projection.MediaProjectionManager();
  public Object getSystemService(String name) {
    return name.equals(WINDOW_SERVICE) ? windows : projections;
  }
}
""",
    "android/os/Build.java": """
package android.os;
public class Build {
  public static class VERSION { public static int SDK_INT = 34; }
  public static class VERSION_CODES { public static final int S = 31; }
}
""",
    "android/os/Handler.java": """
package android.os;
public class Handler {
  public boolean retired;
  private final java.util.ArrayDeque<Runnable> queue = new java.util.ArrayDeque<>();
  private final java.util.ArrayDeque<Runnable> delayed = new java.util.ArrayDeque<>();
  public Handler() {}
  public Handler(Looper looper) {}
  public synchronized boolean post(Runnable runnable) { queue.add(runnable); return true; }
  public synchronized boolean postDelayed(Runnable runnable, long delay) {
    assert delay >= 1000 : "Static frames must not be scheduled faster than 1Hz";
    delayed.add(runnable); return true;
  }
  public synchronized void removeCallbacks(Runnable runnable) {
    queue.removeIf(item -> item == runnable);
    delayed.removeIf(item -> item == runnable);
  }
  public synchronized int pending() { return queue.size(); }
  public synchronized int delayedPending() { return delayed.size(); }
  public void runDelayedOnce() {
    java.util.List<Runnable> due;
    synchronized(this) { due = new java.util.ArrayList<>(delayed); delayed.clear(); }
    for (Runnable runnable : due) runnable.run();
    drain();
  }
  public void drain() {
    while (true) {
      Runnable runnable;
      synchronized (this) { runnable = queue.poll(); }
      if (runnable == null) return;
      runnable.run();
    }
  }
}
""",
    "android/os/Looper.java": """
package android.os;
public class Looper { public static Looper getMainLooper() { return new Looper(); } }
""",
    "android/os/SystemClock.java": """
package android.os;
public class SystemClock {
  public static long now = 10000;
  public static long uptimeMillis() { return now; }
}
""",
    "android/util/DisplayMetrics.java": """
package android.util;
public class DisplayMetrics { public int widthPixels; public int heightPixels; }
""",
    "android/util/Log.java": """
package android.util;
public class Log {
  public static int warnings;
  public static int d(String tag, String message) { return 0; }
  public static int w(String tag, String message, Throwable error) {
    ++warnings; return 0;
  }
}
""",
    "android/view/Display.java": """
package android.view;
public class Display {
  public void getRealMetrics(android.util.DisplayMetrics metrics) {
    metrics.widthPixels = 1080; metrics.heightPixels = 2400;
  }
}
""",
    "android/view/WindowManager.java": """
package android.view;
public class WindowManager { public Display getDefaultDisplay() { return new Display(); } }
""",
    "android/graphics/SurfaceTexture.java": """
package android.graphics;
public class SurfaceTexture { public void setDefaultBufferSize(int width, int height) {} }
""",
    "android/view/Surface.java": """
package android.view;
public class Surface {
  public static int live = 0;
  public final android.graphics.SurfaceTexture texture;
  private boolean released;
  public Surface(android.graphics.SurfaceTexture texture) { this.texture = texture; ++live; }
  public void release() { if (!released) { released = true; --live; } }
}
""",
    "android/hardware/display/DisplayManager.java": """
package android.hardware.display;
public class DisplayManager {
  public static final int VIRTUAL_DISPLAY_FLAG_PUBLIC = 1;
  public static final int VIRTUAL_DISPLAY_FLAG_PRESENTATION = 2;
}
""",
    "android/hardware/display/VirtualDisplay.java": """
package android.hardware.display;
public class VirtualDisplay {
  public static final java.util.List<String> events = new java.util.ArrayList<>();
  public static boolean failAttach;
  public int resizes = 0;
  public boolean released = false;
  public android.view.Surface surface;
  public void resize(int width, int height, int dpi) {
    ++resizes; events.add("resize:" + width + "x" + height);
  }
  public void setSurface(android.view.Surface surface) {
    if (surface != null && failAttach) {
      failAttach = false; throw new IllegalStateException("test attach failure");
    }
    this.surface = surface;
    events.add(surface == null ? "detach" : "attach");
  }
  public void release() { released = true; }
}
""",
    "android/media/projection/MediaProjectionManager.java": """
package android.media.projection;
public class MediaProjectionManager {
  public final MediaProjection projection = new MediaProjection();
  public MediaProjection getMediaProjection(int result, android.content.Intent data) {
    return projection;
  }
}
""",
    "android/media/projection/MediaProjection.java": """
package android.media.projection;
public class MediaProjection {
  public static boolean failCreate;
  public static class Callback {
    public void onStop() {}
    public void onCapturedContentResize(int width, int height) {}
  }
  public Callback callback;
  public android.os.Handler callbackHandler;
  public int creates = 0;
  public int stops = 0;
  public final java.util.List<android.hardware.display.VirtualDisplay> displays =
      new java.util.ArrayList<>();
  public void registerCallback(Callback callback, android.os.Handler handler) {
    this.callback = callback;
    this.callbackHandler = handler;
  }
  public void unregisterCallback(Callback callback) { this.callback = null; }
  public void stop() { ++stops; }
  public android.hardware.display.VirtualDisplay createVirtualDisplay(String name,
      int width, int height, int dpi, int flags, android.view.Surface surface,
      Object callback, Object handler) {
    if (failCreate) { failCreate = false; throw new IllegalStateException("test display failure"); }
    if (++creates > 1 && android.os.Build.VERSION.SDK_INT >= 34) {
      throw new SecurityException("A projection token cannot create two displays");
    }
    android.hardware.display.VirtualDisplay display =
        new android.hardware.display.VirtualDisplay();
    display.surface = surface;
    displays.add(display);
    return display;
  }
}
""",
    "org/webrtc/VideoCapturer.java": """
package org.webrtc;
public interface VideoCapturer {
  void initialize(SurfaceTextureHelper helper, android.content.Context context,
      CapturerObserver observer);
  void startCapture(int width, int height, int fps);
  void stopCapture();
  void changeCaptureFormat(int width, int height, int fps);
  void dispose();
  boolean isScreencast();
}
""",
    "org/webrtc/VideoSink.java": """
package org.webrtc; public interface VideoSink { void onFrame(VideoFrame frame); }
""",
    "org/webrtc/VideoFrame.java": """
package org.webrtc;
public class VideoFrame {
  public static class Buffer {
    public int refs = 1;
    public void retain() { assert refs > 0; ++refs; }
    public void release() { assert refs > 0; --refs; }
  }
  private final Buffer buffer;
  private final int rotation;
  private final long timestamp;
  public VideoFrame(Buffer buffer, int rotation, long timestamp) {
    this.buffer = buffer; this.rotation = rotation; this.timestamp = timestamp;
  }
  public Buffer getBuffer() { return buffer; }
  public int getRotation() { return rotation; }
  public long getTimestampNs() { return timestamp; }
  public void release() { buffer.release(); }
}
""",
    "org/webrtc/CapturerObserver.java": """
package org.webrtc;
public interface CapturerObserver {
  void onCapturerStarted(boolean success);
  void onCapturerStopped();
  void onFrameCaptured(VideoFrame frame);
}
""",
    "org/webrtc/SurfaceTextureHelper.java": """
package org.webrtc;
public class SurfaceTextureHelper {
  public static final java.util.List<SurfaceTextureHelper> helpers = new java.util.ArrayList<>();
  public static boolean failCreate;
  public static boolean failStart;
  public static Runnable onCreate;
  private final android.os.Handler handler = new android.os.Handler();
  private final android.graphics.SurfaceTexture texture = new android.graphics.SurfaceTexture();
  public int width, height, starts, stops, disposals, forcedFrames;
  private VideoSink listener;
  private VideoFrame lastFrame;
  public SurfaceTextureHelper() { helpers.add(this); }
  public static SurfaceTextureHelper create(String name, Object context) {
    if (onCreate != null) onCreate.run();
    if (failCreate) { failCreate = false; return null; }
    return new SurfaceTextureHelper();
  }
  public android.os.Handler getHandler() { return handler; }
  public android.graphics.SurfaceTexture getSurfaceTexture() { return texture; }
  public void setTextureSize(int width, int height) {
    this.width = width; this.height = height;
    android.hardware.display.VirtualDisplay.events.add("size:" + width + "x" + height);
  }
  public void startListening(VideoSink sink) {
    if (failStart) { failStart = false; throw new IllegalStateException("test listener failure"); }
    ++starts; listener = sink;
  }
  public void emit(VideoFrame frame) { lastFrame = frame; if (listener != null) listener.onFrame(frame); }
  public void forceFrame() {
    assert !handler.retired : "Refreshing a disposed capture helper";
    ++forcedFrames;
    handler.post(() -> { if (listener != null && lastFrame != null) listener.onFrame(lastFrame); });
  }
  public void stopListening() { ++stops; listener = null; }
  public void dispose() { ++disposals; handler.retired = true; }
}
""",
    "com/cloudwebrtc/webrtc/utils/EglUtils.java": """
package com.cloudwebrtc.webrtc.utils;
public class EglUtils { public static Object getRootEglBaseContext() { return new Object(); } }
""",
    "org/webrtc/ThreadUtils.java": """
package org.webrtc;
public class ThreadUtils {
  public static Runnable beforeInvoke;
  public static void invokeAtFrontUninterruptibly(android.os.Handler handler, Runnable runnable) {
    if (beforeInvoke != null) beforeInvoke.run();
    if (handler.retired) throw new AssertionError("Posted stop to a retired helper");
    Thread captureThread = new Thread(() -> {
      // A resize can already be dequeued when stop waits for the capture thread.
      handler.drain();
      runnable.run();
    });
    captureThread.setDaemon(true);
    captureThread.start();
    try { captureThread.join(2000); }
    catch (InterruptedException error) { throw new AssertionError(error); }
    if (captureThread.isAlive()) throw new AssertionError("Capture stop deadlocked");
  }
}
""",
}


TEST = """
import com.cloudwebrtc.webrtc.OrientationAwareScreenCapturer;
import android.content.Context;
import android.media.projection.MediaProjection;
import org.webrtc.SurfaceTextureHelper;

public class ScreenCapturerTest {
  static void await(java.util.concurrent.CountDownLatch latch) {
    try { assert latch.await(2, java.util.concurrent.TimeUnit.SECONDS); }
    catch (InterruptedException error) { throw new AssertionError(error); }
  }
  static void join(Thread thread) {
    try { thread.join(2000); }
    catch (InterruptedException error) { throw new AssertionError(error); }
    assert !thread.isAlive() : "Lifecycle operation deadlocked";
  }
  static class Observer implements org.webrtc.CapturerObserver {
    int starts, stops;
    boolean failFrame;
    final java.util.List<Long> timestamps = new java.util.ArrayList<>();
    public void onCapturerStarted(boolean success) { assert success; ++starts; }
    public void onCapturerStopped() { ++stops; }
    public void onFrameCaptured(org.webrtc.VideoFrame frame) {
      if (failFrame) throw new IllegalStateException("test frame failure");
      timestamps.add(frame.getTimestampNs());
    }
  }
  static class Fixture {
    final Context context = new Context();
    final SurfaceTextureHelper helper = new SurfaceTextureHelper();
    final Observer observer = new Observer();
    final MediaProjection projection = context.projections.projection;
    final OrientationAwareScreenCapturer capturer;
    Fixture(int sdk) {
      this(sdk, true);
    }
    Fixture(int sdk, boolean start) {
      this(sdk, start, 0);
    }
    Fixture(int sdk, boolean start, int maxShortSide) {
      android.os.Build.VERSION.SDK_INT = sdk;
      capturer = new OrientationAwareScreenCapturer(
          new android.content.Intent(), null, maxShortSide);
      capturer.initialize(helper, context, observer);
      if (start) capturer.startCapture(1280, 720, 30);
    }
  }
  public static void main(String[] args) {
    Fixture futureClock = new Fixture(34);
    long futureTimestamp = System.nanoTime() + 3600000000000L;
    org.webrtc.VideoFrame.Buffer futureBuffer = new org.webrtc.VideoFrame.Buffer();
    futureClock.helper.emit(new org.webrtc.VideoFrame(futureBuffer, 0, futureTimestamp));
    try {
      java.lang.reflect.Field delivery = OrientationAwareScreenCapturer.class
          .getDeclaredField("lastFrameDeliveryTimeNs");
      delivery.setAccessible(true);
      delivery.setLong(futureClock.capturer, System.nanoTime() - 1000000000L);
    } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
    android.os.SystemClock.now += 1000;
    futureClock.helper.getHandler().runDelayedOnce();
    assert futureClock.observer.timestamps.get(1) - futureTimestamp >= 1000000000L
        : "Ahead-of-uptime source clock replay advanced too little for the frame-rate adapter";
    assert futureBuffer.refs == 1;
    futureClock.capturer.dispose();
    for (int sdk : new int[] {24, 31, 34, 36}) {
      Fixture idle = new Fixture(sdk);
      assert idle.helper.getHandler().delayedPending() == 1;
      android.os.SystemClock.now += 1000;
      idle.helper.getHandler().runDelayedOnce();
      assert idle.helper.forcedFrames == 0 : "Must not replay an uninitialized texture";
      org.webrtc.VideoFrame.Buffer buffer = new org.webrtc.VideoFrame.Buffer();
      idle.helper.emit(new org.webrtc.VideoFrame(buffer, 0, 1000000000));
      android.os.SystemClock.now += 500;
      idle.helper.getHandler().runDelayedOnce();
      assert idle.helper.forcedFrames == 0 : "Real frames must suppress duplicate work";
      android.os.SystemClock.now += 500;
      idle.helper.getHandler().runDelayedOnce();
      assert idle.helper.forcedFrames == 1;
      assert idle.observer.timestamps.size() == 2;
      assert idle.observer.timestamps.get(1) > idle.observer.timestamps.get(0)
          : "Replayed frame retained a duplicate timestamp and would be discarded";
      assert buffer.refs == 1 : "Refreshing leaked or consumed the original texture";
      android.os.SystemClock.now += 900;
      idle.helper.emit(new org.webrtc.VideoFrame(buffer, 0, idle.observer.timestamps.get(1) + 1));
      android.os.SystemClock.now += 100;
      idle.helper.getHandler().runDelayedOnce();
      assert idle.helper.forcedFrames == 1 : "Continuous capture must not add forced frames";
      idle.projection.callback.onCapturedContentResize(2400, 1080);
      idle.helper.getHandler().drain();
      SurfaceTextureHelper current = sdk < 31 ? idle.helper :
          SurfaceTextureHelper.helpers.get(SurfaceTextureHelper.helpers.size() - 1);
      if (current != idle.helper) assert idle.helper.getHandler().delayedPending() == 0;
      int forced = current.forcedFrames;
      android.os.SystemClock.now += 1000;
      current.getHandler().runDelayedOnce();
      assert current.forcedFrames == forced : "Resize replayed the previous dimensions before a new frame";
      org.webrtc.VideoFrame.Buffer rotatedBuffer = new org.webrtc.VideoFrame.Buffer();
      current.emit(new org.webrtc.VideoFrame(rotatedBuffer, 0, 1000000001));
      android.os.SystemClock.now += 1000;
      current.getHandler().runDelayedOnce();
      assert current.forcedFrames == forced + 1;
      assert current.getHandler().delayedPending() == 1 : "Refresh loop duplicated after rotation";
      idle.observer.failFrame = true;
      android.os.SystemClock.now += 1000;
      try { current.getHandler().runDelayedOnce(); throw new AssertionError("Expected observer failure"); }
      catch (IllegalStateException expected) {}
      assert rotatedBuffer.refs == 1 : "Observer failure leaked a retained replay texture";
      idle.projection.callback.onStop();
      assert current.getHandler().delayedPending() == 0 : "Revocation retained the refresh task";
      assert current.getHandler().pending() == 0;
      current.getHandler().runDelayedOnce();
      assert android.view.Surface.live == 0;
    }
    for (int sdk : new int[] {24, 31, 34, 36}) {
      for (int cap : new int[] {480, 720, 1080, 1440, 0}) {
        Fixture limited = new Fixture(sdk, true, cap);
        int shortSide = limited.helper.width;
        int longSide = limited.helper.height;
        assert shortSide <= 1080 && longSide <= 2400 : "Capture must not upscale";
        assert cap == 0 || shortSide <= cap : "Resolution limit ignored";
        assert Math.abs((double) longSide / shortSide - 2400.0 / 1080) < 0.01;
        limited.projection.callback.onCapturedContentResize(2400, 1080);
        limited.helper.getHandler().drain();
        SurfaceTextureHelper output = SurfaceTextureHelper.helpers.get(SurfaceTextureHelper.helpers.size() - 1);
        if (sdk < 31) output = limited.helper;
        assert output.width == longSide && output.height == shortSide : "Rotation changed capture proportions";
        int creates = limited.projection.creates;
        int helpers = SurfaceTextureHelper.helpers.size();
        limited.projection.callback.onCapturedContentResize(2400, 1080);
        output.getHandler().drain();
        assert limited.projection.creates == creates && SurfaceTextureHelper.helpers.size() == helpers
            : "Unchanged resolution duplicated capture resources";
        limited.capturer.dispose();
        assert android.view.Surface.live == 0;
      }
    }
    for (boolean failDisplay : new boolean[] {false, true}) {
      Fixture startup = new Fixture(34, false);
      MediaProjection.failCreate = failDisplay;
      SurfaceTextureHelper.failStart = !failDisplay;
      try {
        startup.capturer.startCapture(1280, 720, 30);
        throw new AssertionError("Expected startup failure");
      } catch (IllegalStateException expected) {}
      startup.capturer.dispose();
      assert startup.projection.stops == 1 && startup.projection.callback == null;
      assert startup.helper.disposals == 1;
      assert android.view.Surface.live == 0 : "Partial start leaked its Surface";
      for (android.hardware.display.VirtualDisplay display : startup.projection.displays) {
        assert display.released : "Partial start leaked its VirtualDisplay";
      }
    }
    for (int sdk : new int[] {24, 29, 30, 31, 34, 36}) {
      SurfaceTextureHelper.helpers.clear();
      Fixture f = new Fixture(sdk);
      f.capturer.startCapture(1280, 720, 30);
      assert f.projection.creates == 1 : "Duplicate start created another display";
      assert f.observer.starts == 1;
      assert f.projection.callbackHandler != f.helper.getHandler()
          : "Projection callbacks must outlive replaced capture helpers";
      android.hardware.display.VirtualDisplay.events.clear();
      f.capturer.changeCaptureFormat(2400, 1080, 30);
      f.capturer.changeCaptureFormat(2200, 1080, 30);
      assert f.helper.getHandler().pending() == 1 : "Resize requests must coalesce";
      f.helper.getHandler().drain();
      SurfaceTextureHelper current = SurfaceTextureHelper.helpers.get(
          SurfaceTextureHelper.helpers.size() - 1);
      assert current.width == 2200 && current.height == 1080;
      assert f.helper.getHandler().pending() == 0 : "Redundant delayed resizes remained";
      if (sdk < 31) {
        assert f.projection.creates == 2;
        assert f.projection.displays.get(0).released;
      } else {
        assert f.projection.creates == 1;
        assert f.projection.displays.get(0).resizes == 1;
        assert android.hardware.display.VirtualDisplay.events.equals(
            java.util.Arrays.asList("size:2200x1080", "resize:2200x1080", "attach"))
            : "New texture size must precede virtual-display geometry and attachment";
        assert f.projection.displays.get(0).surface.texture != f.helper.getSurfaceTexture()
            : "Resize must replace the BufferQueue producer, not just the Surface wrapper";
        assert f.helper.stops == 1 && f.helper.disposals == 1;
        assert current.starts == 1 && current.disposals == 0;
      }
      assert android.view.Surface.live == 1 : "Replaced surface was not released";
      if (sdk < 31) assert f.helper.starts == 1 && f.helper.stops == 0;
      f.capturer.changeCaptureFormat(2200, 1080, 30);
      assert current.getHandler().pending() == 0;
      f.capturer.changeCaptureFormat(1080, 2400, 30);
      f.capturer.stopCapture();
      assert current.getHandler().pending() == 0;
      assert android.view.Surface.live == 0;
      assert f.observer.stops == 1;
      f.capturer.stopCapture();
      f.capturer.dispose();
      f.capturer.dispose();
      for (SurfaceTextureHelper helper : SurfaceTextureHelper.helpers) {
        assert helper.disposals == 1 : "Each capture helper must be disposed exactly once";
        assert helper.getHandler().delayedPending() == 0 : "Stopped helper retained a refresh task";
      }
      int listenerStops = f.helper.stops;
      f.capturer.stopCapture();
      assert f.helper.stops == listenerStops : "Stop after disposal touched the helper";
      assert f.observer.stops == 1;
      assert f.projection.stops == 1;
    }
    Fixture revoked = new Fixture(34);
    MediaProjection.Callback callback = revoked.projection.callback;
    callback.onCapturedContentResize(2400, 1080);
    callback.onStop();
    callback.onCapturedContentResize(1080, 2400);
    assert revoked.helper.getHandler().pending() == 0;
    assert revoked.helper.disposals == 1 : "System revocation must retire the capture helper";
    assert android.view.Surface.live == 0;
    assert revoked.observer.stops == 1;
    revoked.capturer.dispose();
    assert revoked.helper.disposals == 1;
    for (boolean createFails : new boolean[] {true, false}) {
      SurfaceTextureHelper.helpers.clear();
      Fixture rollback = new Fixture(34);
      SurfaceTextureHelper.failCreate = createFails;
      android.hardware.display.VirtualDisplay.failAttach = !createFails;
      int warnings = android.util.Log.warnings;
      rollback.capturer.changeCaptureFormat(2400, 1080, 30);
      rollback.helper.getHandler().drain();
      assert android.util.Log.warnings == warnings + 1;
      assert rollback.projection.displays.get(0).surface.texture
          == rollback.helper.getSurfaceTexture() : "Resize failure lost the old producer";
      assert rollback.helper.disposals == 0 : "Resize failure disposed the usable helper";
      assert rollback.helper.getHandler().delayedPending() == 1
          : "Resize rollback lost or duplicated the refresh task";
      assert android.view.Surface.live == 1;
      rollback.capturer.changeCaptureFormat(2400, 1080, 30);
      assert rollback.helper.getHandler().pending() == 1
          : "Failed resize was incorrectly marked applied";
      rollback.helper.getHandler().drain();
      rollback.capturer.dispose();
      assert android.view.Surface.live == 0;
      for (SurfaceTextureHelper helper : SurfaceTextureHelper.helpers) {
        assert helper.disposals == 1 : "Rollback leaked or double-disposed a helper";
      }
    }
    SurfaceTextureHelper.helpers.clear();
    Fixture racing = new Fixture(34);
    java.util.concurrent.CountDownLatch replacing = new java.util.concurrent.CountDownLatch(1);
    java.util.concurrent.CountDownLatch finishReplacement = new java.util.concurrent.CountDownLatch(1);
    java.util.concurrent.atomic.AtomicReference<Throwable> failure =
        new java.util.concurrent.atomic.AtomicReference<>();
    SurfaceTextureHelper.onCreate = () -> { replacing.countDown(); await(finishReplacement); };
    racing.capturer.changeCaptureFormat(2400, 1080, 30);
    Thread handoff = new Thread(() -> {
      try { racing.helper.getHandler().drain(); }
      catch (Throwable error) { failure.set(error); }
    });
    handoff.start();
    await(replacing);
    Thread stop = new Thread(() -> {
      try { racing.capturer.stopCapture(); }
      catch (Throwable error) { failure.set(error); }
    });
    stop.start();
    finishReplacement.countDown();
    join(handoff); join(stop);
    SurfaceTextureHelper.onCreate = null;
    assert failure.get() == null : failure.get();
    assert racing.observer.stops == 1;
    racing.capturer.dispose();
    assert android.view.Surface.live == 0;
    for (SurfaceTextureHelper helper : SurfaceTextureHelper.helpers) assert helper.disposals == 1;
    Fixture concurrentDispose = new Fixture(34);
    java.util.concurrent.CountDownLatch retainedStop = new java.util.concurrent.CountDownLatch(1);
    java.util.concurrent.CountDownLatch dispatchStop = new java.util.concurrent.CountDownLatch(1);
    java.util.concurrent.atomic.AtomicBoolean firstStop = new java.util.concurrent.atomic.AtomicBoolean(true);
    org.webrtc.ThreadUtils.beforeInvoke = () -> {
      if (firstStop.compareAndSet(true, false)) { retainedStop.countDown(); await(dispatchStop); }
    };
    Thread retained = new Thread(() -> {
      try { concurrentDispose.capturer.stopCapture(); }
      catch (Throwable error) { failure.set(error); }
    });
    retained.start();
    await(retainedStop);
    concurrentDispose.capturer.dispose();
    assert concurrentDispose.helper.disposals == 0
        : "Dispose retired a helper while another stop still held it";
    dispatchStop.countDown();
    join(retained);
    org.webrtc.ThreadUtils.beforeInvoke = null;
    assert failure.get() == null : failure.get();
    assert concurrentDispose.helper.disposals == 1;
    assert concurrentDispose.observer.stops == 1;
    assert concurrentDispose.projection.stops == 1;
    assert android.view.Surface.live == 0;
    System.out.println("Android capturer: API 24/29/30/31/34/36 resize, coalescing, stop, "
        + "revocation, static-frame refresh/timestamps, failed handoff rollback, concurrent stop/dispose and cleanup passed.");
  }
}
"""


def main():
    plugin = Path(__file__).resolve().parents[2]
    capturer = plugin / "android/src/main/java/com/cloudwebrtc/webrtc/OrientationAwareScreenCapturer.java"
    with tempfile.TemporaryDirectory(prefix="bshare-screen-capturer-") as temporary:
        directory = Path(temporary)
        sources = []
        for name, content in {**STUBS, "ScreenCapturerTest.java": TEST}.items():
            source = directory / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(content)
            sources.append(str(source))
        subprocess.run(["javac", "-d", temporary, *sources, str(capturer)], check=True)
        subprocess.run(["java", "-ea", "-cp", temporary, "ScreenCapturerTest"], check=True)


if __name__ == "__main__":
    main()
