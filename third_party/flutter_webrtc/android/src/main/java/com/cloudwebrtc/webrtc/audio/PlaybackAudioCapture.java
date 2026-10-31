package com.cloudwebrtc.webrtc.audio;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;

import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;

/** Feeds Android playback PCM into WebRTC's virtual recording device, never its microphone. */
public final class PlaybackAudioCapture implements JavaAudioDeviceModule.AudioBufferCallback {
    private final Object lock = new Object();
    private final Runnable onFailure;
    private MediaProjection projection;
    private Capture capture;

    private static final class Capture {
        final AudioRecord record;
        final byte[] frame;
        final int sampleRate;
        final int channels;
        int readers;
        boolean stopped;
        boolean stopCompleted;
        boolean released;

        Capture(AudioRecord record, int size, int sampleRate, int channels) {
            this.record = record;
            this.frame = new byte[size];
            this.sampleRate = sampleRate;
            this.channels = channels;
        }
    }

    public PlaybackAudioCapture(Runnable onFailure) {
        this.onFailure = onFailure;
    }

    public boolean isConfigured() {
        synchronized (lock) {
            return projection != null;
        }
    }

    public void start(MediaProjection projection) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || projection == null) {
            throw new IllegalStateException("Playback capture requires Android 10 and screen consent");
        }
        stop();
        synchronized (lock) {
            this.projection = projection;
        }
    }

    public void stop() {
        final Capture stopped;
        synchronized (lock) {
            projection = null;
            stopped = capture;
            capture = null;
            if (stopped != null) stopped.stopped = true;
        }
        if (stopped == null) return;
        // Do not hold lock while stopping a blocking read. Its finally block
        // releases the record after the last reader, including concurrent stop.
        try {
            stopped.record.stop();
        } catch (RuntimeException error) {
            Log.w("BSharePlaybackAudio", "Playback capture stop failed", error);
        } finally {
            synchronized (lock) {
                stopped.stopCompleted = true;
                releaseIfIdle(stopped);
            }
        }
    }

    private void releaseIfIdle(Capture value) {
        if (value.stopCompleted && value.readers == 0 && !value.released) {
            value.released = true;
            value.record.release();
        }
    }

    @Override
    public long onBuffer(ByteBuffer buffer, int format, int channels, int sampleRate,
                         int bytesRead, long timestampNs) {
        final Capture current;
        try {
            synchronized (lock) {
                if (projection == null) {
                    if (bytesRead == 0) SystemClock.sleep(10);
                    return timestampNs;
                }
                if (format != AudioFormat.ENCODING_PCM_16BIT || (channels != 1 && channels != 2)) {
                    throw new IllegalStateException("Unsupported playback PCM format");
                }
                if (capture == null) capture = openCapture(projection, buffer.capacity(), sampleRate, channels);
                current = capture;
                if (current.sampleRate != sampleRate || current.channels != channels ||
                        current.frame.length != buffer.capacity()) {
                    throw new IllegalStateException("Playback audio format changed during capture");
                }
                current.readers++;
            }
        } catch (RuntimeException error) {
            fail(error);
            silence(buffer);
            SystemClock.sleep(10);
            return System.nanoTime();
        }

        try {
            int read = current.record.read(current.frame, 0, current.frame.length, AudioRecord.READ_BLOCKING);
            if (read < 0) {
                if (isConfigured()) throw new IllegalStateException("Playback audio read failed: " + read);
                read = 0;
            }
            final ByteBuffer output = buffer.duplicate();
            output.clear();
            output.put(current.frame, 0, read);
            while (output.hasRemaining()) output.put((byte) 0);
            if (read == 0) SystemClock.sleep(10);
            return System.nanoTime();
        } catch (RuntimeException error) {
            if (isConfigured()) fail(error);
            silence(buffer);
            SystemClock.sleep(10);
            return System.nanoTime();
        } finally {
            synchronized (lock) {
                current.readers--;
                releaseIfIdle(current);
            }
        }
    }

    private static Capture openCapture(MediaProjection projection, int size, int sampleRate, int channels) {
        int channelMask = channels == 2 ? AudioFormat.CHANNEL_IN_STEREO : AudioFormat.CHANNEL_IN_MONO;
        int minimum = AudioRecord.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT);
        if (minimum <= 0) throw new IllegalStateException("Playback sample rate is unavailable");
        AudioPlaybackCaptureConfiguration configuration =
                new AudioPlaybackCaptureConfiguration.Builder(projection)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                        .build();
        AudioRecord record = new AudioRecord.Builder()
                .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate).setChannelMask(channelMask).build())
                .setAudioPlaybackCaptureConfig(configuration)
                .setBufferSizeInBytes(Math.max(minimum, size * 4)).build();
        try {
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                throw new IllegalStateException("Playback recording could not initialize");
            }
            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                throw new IllegalStateException("Playback recording could not start");
            }
            return new Capture(record, size, sampleRate, channels);
        } catch (RuntimeException error) {
            record.release();
            throw error;
        }
    }

    private void fail(RuntimeException error) {
        final boolean notify = isConfigured();
        stop();
        Log.w("BSharePlaybackAudio", "Playback audio unavailable", error);
        if (notify && onFailure != null) onFailure.run();
    }

    private static void silence(ByteBuffer buffer) {
        final ByteBuffer output = buffer.duplicate();
        output.clear();
        while (output.hasRemaining()) output.put((byte) 0);
    }
}
