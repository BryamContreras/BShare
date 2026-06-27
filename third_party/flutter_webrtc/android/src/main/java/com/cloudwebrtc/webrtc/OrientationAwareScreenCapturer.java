package com.cloudwebrtc.webrtc;

import org.webrtc.SurfaceTextureHelper;
import org.webrtc.CapturerObserver;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoCapturer;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;

import android.annotation.TargetApi;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjection;
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
    private int width;
    private int height;
    private int oldWidth;
    private int oldHeight;
    private VirtualDisplay virtualDisplay;
    private Surface virtualDisplaySurface;
    private SurfaceTextureHelper surfaceTextureHelper;
    private CapturerObserver capturerObserver;
    private long numCapturedFrames = 0;
    private MediaProjection mediaProjection;
    private boolean isDisposed = false;
    private MediaProjectionManager mediaProjectionManager;
    private WindowManager windowManager;
    private boolean resizePending = false;
    private boolean usesCapturedContentResize = false;
    private int pendingWidth;
    private int pendingHeight;
    private int resizeSerial = 0;

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
        this.mediaProjectionPermissionResultData = mediaProjectionPermissionResultData;
        this.externalMediaProjectionCallback = mediaProjectionCallback;
        this.mediaProjectionCallback = new MediaProjection.Callback() {
            @Override
            public void onStop() {
                if (externalMediaProjectionCallback != null) {
                    externalMediaProjectionCallback.onStop();
                }
            }

            @Override
            public void onCapturedContentResize(int width, int height) {
                usesCapturedContentResize = true;
                Log.d(TAG, "Captured content resized to " + width + "x" + height);
                requestCaptureFormat(width, height);
            }
        };
    }

    public void onFrame(VideoFrame frame) {
        checkNotDisposed();
        numCapturedFrames++;
        maybeUpdateCaptureFormatFromDisplay();
        capturerObserver.onFrameCaptured(frame);
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
        //checkNotDisposed();

        final DisplayMetrics metrics = currentDisplayMetrics();
        this.width = metrics.widthPixels > 0 ? metrics.widthPixels : width;
        this.height = metrics.heightPixels > 0 ? metrics.heightPixels : height;
        this.oldWidth = this.width;
        this.oldHeight = this.height;

        mediaProjection = mediaProjectionManager.getMediaProjection(
                Activity.RESULT_OK, mediaProjectionPermissionResultData);

        // Let MediaProjection callback use the SurfaceTextureHelper thread.
        mediaProjection.registerCallback(mediaProjectionCallback, surfaceTextureHelper.getHandler());

        createVirtualDisplay();
        capturerObserver.onCapturerStarted(true);
        surfaceTextureHelper.startListening(this);
    }

    @Override
    public synchronized void stopCapture() {
        checkNotDisposed();
        ThreadUtils.invokeAtFrontUninterruptibly(surfaceTextureHelper.getHandler(), new Runnable() {
            @Override
            public void run() {
                surfaceTextureHelper.stopListening();
                capturerObserver.onCapturerStopped();
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
    public synchronized void dispose() {
        isDisposed = true;
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
        if (nextWidth <= 0 || nextHeight <= 0 || surfaceTextureHelper == null) {
            return;
        }
        pendingWidth = nextWidth;
        pendingHeight = nextHeight;
        if (resizePending || (this.oldWidth == nextWidth && this.oldHeight == nextHeight)) {
            return;
        }
        resizePending = true;
        surfaceTextureHelper.getHandler().post(new Runnable() {
            @Override
            public void run() {
                applyPendingCaptureFormat();
            }
        });
    }

    private synchronized void applyPendingCaptureFormat() {
        try {
            if (isDisposed || surfaceTextureHelper == null || mediaProjection == null) {
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
            resizeSerial++;
            scheduleStabilizingResize(resizeSerial, 350);
            scheduleStabilizingResize(resizeSerial, 900);
            scheduleStabilizingResize(resizeSerial, 1500);
            Log.d(TAG, "Screen capture resized to " + width + "x" + height);
        } catch (Throwable error) {
            Log.w(TAG, "Screen capture resize failed", error);
        } finally {
            resizePending = false;
        }
    }

    private void scheduleStabilizingResize(final int serial, final long delayMillis) {
        surfaceTextureHelper.getHandler().postDelayed(new Runnable() {
            @Override
            public void run() {
                applyStabilizingResize(serial);
            }
        }, delayMillis);
    }

    private synchronized void applyStabilizingResize(final int serial) {
        if (serial != resizeSerial || isDisposed || surfaceTextureHelper == null || mediaProjection == null) {
            return;
        }
        try {
            resizeVirtualDisplay();
            Log.d(TAG, "Screen capture surface refreshed at " + width + "x" + height);
        } catch (Throwable error) {
            Log.w(TAG, "Screen capture surface refresh failed", error);
        }
    }

    private void createVirtualDisplay() {
        updateSurfaceTextureSize();
        releaseVirtualDisplaySurface();
        virtualDisplaySurface = new Surface(surfaceTextureHelper.getSurfaceTexture());
        virtualDisplay = mediaProjection.createVirtualDisplay("WebRTC_ScreenCapture", width, height,
                VIRTUAL_DISPLAY_DPI, DISPLAY_FLAGS, virtualDisplaySurface,
                null /* callback */, null /* callback handler */);
    }

    private void resizeVirtualDisplay() {
        if (virtualDisplay != null) {
            surfaceTextureHelper.stopListening();
            final Surface oldSurface = virtualDisplaySurface;
            virtualDisplay.setSurface(null);
            if (oldSurface != null) {
                oldSurface.release();
            }
            virtualDisplaySurface = null;
            updateSurfaceTextureSize();
            virtualDisplay.resize(width, height, VIRTUAL_DISPLAY_DPI);
            virtualDisplaySurface = new Surface(surfaceTextureHelper.getSurfaceTexture());
            virtualDisplay.setSurface(virtualDisplaySurface);
            surfaceTextureHelper.startListening(this);
        } else {
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
