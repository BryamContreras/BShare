/*
 * Copyright 2017, Lyo Kato <lyo.kato at gmail.com>
 * Copyright 2017-2021, Shiguredo Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.cloudwebrtc.webrtc;

import org.webrtc.VideoCodecStatus;
import org.webrtc.VideoEncoder;
import org.webrtc.VideoFrame;

import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/** Serializes a Java encoder and owns the worker for one encoding session. */
final class ThreadedVideoEncoder implements VideoEncoder {
    private final VideoEncoder encoder;
    private ExecutorService executor;
    private Settings settings;

    ThreadedVideoEncoder(VideoEncoder encoder) {
        this.encoder = encoder;
    }

    private synchronized <T> T call(Callable<T> operation) {
        if (executor == null) {
            executor = Executors.newSingleThreadExecutor(runnable ->
                    new Thread(runnable, "BShareVideoEncoder"));
        }
        return await(executor.submit(operation));
    }

    private static <T> T await(Future<T> future) {
        boolean interrupted = false;
        try {
            for (;;) {
                try {
                    return future.get();
                } catch (InterruptedException error) {
                    // JNI calls are synchronous: do not let the owner release a
                    // frame while the worker is still reading its buffer.
                    interrupted = true;
                } catch (ExecutionException error) {
                    Throwable cause = error.getCause();
                    if (cause instanceof RuntimeException) throw (RuntimeException) cause;
                    if (cause instanceof Error) throw (Error) cause;
                    throw new IllegalStateException("Video encoder operation failed", cause);
                }
            }
        } finally {
            if (interrupted) Thread.currentThread().interrupt();
        }
    }

    @Override
    public synchronized VideoCodecStatus initEncode(Settings settings, Callback callback) {
        this.settings = settings;
        return call(() -> encoder.initEncode(settings, callback));
    }

    @Override
    public synchronized VideoCodecStatus release() {
        if (executor == null) return VideoCodecStatus.OK;
        ExecutorService retiring = executor;
        try {
            return await(retiring.submit(encoder::release));
        } finally {
            settings = null;
            executor = null;
            // release() can be followed by initEncode() on the same encoder.
            // Retire this worker now; the next session creates its own worker.
            retiring.shutdown();
        }
    }

    @Override
    public synchronized VideoCodecStatus encode(VideoFrame frame, EncodeInfo info) {
        return call(() -> {
            VideoFrame.Buffer buffer = frame.getBuffer();
            if (settings == null || (buffer.getWidth() == settings.width
                    && buffer.getHeight() == settings.height)) {
                return encoder.encode(frame, info);
            }
            VideoFrame.Buffer adapted = buffer.cropAndScale(
                    0, 0, buffer.getWidth(), buffer.getHeight(), settings.width, settings.height);
            VideoFrame adaptedFrame = new VideoFrame(adapted, frame.getRotation(), frame.getTimestampNs());
            try {
                return encoder.encode(adaptedFrame, info);
            } finally {
                adaptedFrame.release();
            }
        });
    }

    @Override
    public VideoCodecStatus setRateAllocation(BitrateAllocation allocation, int frameRate) {
        return call(() -> encoder.setRateAllocation(allocation, frameRate));
    }

    @Override
    public ScalingSettings getScalingSettings() {
        return call(encoder::getScalingSettings);
    }

    @Override
    public String getImplementationName() {
        // WebRTC explicitly permits this getter from arbitrary threads. Avoid
        // recreating a retired worker merely to read its diagnostic name.
        return encoder.getImplementationName();
    }

    @Override
    public long createNative(long webrtcEnvRef) {
        return call(() -> encoder.createNative(webrtcEnvRef));
    }

    @Override
    public boolean isHardwareEncoder() {
        return call(encoder::isHardwareEncoder);
    }

    @Override
    public VideoCodecStatus setRates(RateControlParameters parameters) {
        return call(() -> encoder.setRates(parameters));
    }

    @Override
    public ResolutionBitrateLimits[] getResolutionBitrateLimits() {
        return call(encoder::getResolutionBitrateLimits);
    }

    @Override
    public EncoderInfo getEncoderInfo() {
        return call(encoder::getEncoderInfo);
    }
}
