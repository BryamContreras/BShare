#!/usr/bin/env python3
"""Run production playback PCM/lifecycle code against Android API doubles.

The separate recording-gate test verifies that WebRTC never opens the microphone
in playback mode. These checks validate PCM delivery, capture configuration,
short/error reads, and stop/restart ownership; device audio still needs a test.
"""

from pathlib import Path
import subprocess
import tempfile


STUBS = {
    'android/os/Build.java': '''package android.os;
public class Build { public static class VERSION { public static int SDK_INT=34; }
public static class VERSION_CODES { public static final int Q=29; }}''',
    'android/os/SystemClock.java': '''package android.os;
public class SystemClock {public static void sleep(long millis){try{Thread.sleep(millis);}catch(InterruptedException error){Thread.currentThread().interrupt();}}}''',
    'android/util/Log.java': '''package android.util;
public class Log {public static void w(String tag,String message,Throwable error){}}''',
    'android/media/projection/MediaProjection.java': 'package android.media.projection; public class MediaProjection {}',
    'android/media/AudioAttributes.java': '''package android.media;
public class AudioAttributes {public static final int USAGE_UNKNOWN=0, USAGE_MEDIA=1, USAGE_GAME=14;}''',
    'android/media/AudioFormat.java': '''package android.media;
public class AudioFormat {public static final int ENCODING_PCM_16BIT=2, CHANNEL_IN_STEREO=12, CHANNEL_IN_MONO=16;
int rate, channels;
public static class Builder {private final AudioFormat value=new AudioFormat();
public Builder setEncoding(int encoding){check(encoding==2);return this;}
public Builder setSampleRate(int rate){value.rate=rate;return this;}
public Builder setChannelMask(int channels){value.channels=channels;return this;}
public AudioFormat build(){return value;}private void check(boolean value){if(!value)throw new AssertionError();}}}''',
    'android/media/AudioPlaybackCaptureConfiguration.java': '''package android.media;
import android.media.projection.MediaProjection;import java.util.*;
public class AudioPlaybackCaptureConfiguration {public final Set<Integer> usages=new HashSet<>();public MediaProjection projection;
public static class Builder {private final AudioPlaybackCaptureConfiguration value=new AudioPlaybackCaptureConfiguration();
public Builder(MediaProjection projection){value.projection=projection;}
public Builder addMatchingUsage(int usage){value.usages.add(usage);return this;}
public AudioPlaybackCaptureConfiguration build(){return value;}}}''',
    'android/media/AudioRecord.java': '''package android.media;
import java.util.*;import java.util.concurrent.*;
public class AudioRecord {
public static final int READ_BLOCKING=0, STATE_INITIALIZED=1, RECORDSTATE_RECORDING=3;
public static final List<AudioRecord> instances=new ArrayList<>();
public static boolean failBuild, failStart, blockNextRead;public static int nextRead=0;
public AudioFormat format;public AudioPlaybackCaptureConfiguration configuration;public int bufferSize;
public int starts,stops,releases,reads;public boolean running;
public final CountDownLatch entered=new CountDownLatch(1), stopped=new CountDownLatch(1);
public static int getMinBufferSize(int rate,int mask,int format){return 1920;}
public int getState(){return STATE_INITIALIZED;}public int getRecordingState(){return running?3:1;}
public void startRecording(){starts++;if(failStart){failStart=false;throw new IllegalStateException("start denied");}running=true;}
public void stop(){stops++;running=false;stopped.countDown();}
public void release(){releases++;if(releases>1)throw new AssertionError("double release");}
public int read(byte[] frame,int offset,int length,int mode){
reads++;entered.countDown();if(blockNextRead){blockNextRead=false;try{stopped.await();}catch(InterruptedException error){throw new RuntimeException(error);}return -3;}
int count=nextRead==0?length:nextRead;nextRead=0;
if(count<0)return count;for(int index=0;index<count;index++)frame[offset+index]=(byte)(index+1);return count;}
public static class Builder {final AudioRecord value=new AudioRecord();
public Builder setAudioFormat(AudioFormat format){value.format=format;return this;}
public Builder setAudioPlaybackCaptureConfig(AudioPlaybackCaptureConfiguration config){value.configuration=config;return this;}
public Builder setBufferSizeInBytes(int bytes){value.bufferSize=bytes;return this;}
public AudioRecord build(){if(failBuild){failBuild=false;throw new SecurityException("projection denied");}instances.add(value);return value;}}
}''',
    'org/webrtc/audio/JavaAudioDeviceModule.java': '''package org.webrtc.audio;
import java.nio.ByteBuffer;
public class JavaAudioDeviceModule {public interface AudioBufferCallback {long onBuffer(ByteBuffer data,int format,int channels,int rate,int read,long timestamp);}}''',
}

HARNESS = r'''
import java.nio.*;import java.util.*;import java.util.concurrent.*;
import android.media.*;import android.media.projection.*;
import com.cloudwebrtc.webrtc.audio.PlaybackAudioCapture;
public class PlaybackAudioCaptureTest {
static void check(boolean result,String label){if(!result)throw new AssertionError(label);}
public static void main(String[] args)throws Exception{
int[] failures={0};PlaybackAudioCapture capture=new PlaybackAudioCapture(()->failures[0]++);
ByteBuffer frame=ByteBuffer.allocateDirect(960);for(int i=0;i<960;i++)frame.put(i,(byte)77);
capture.onBuffer(frame,2,1,48000,960,123);check(frame.get(0)==77,"microphone/remote path is untouched when playback disabled");
android.os.Build.VERSION.SDK_INT=28;try{capture.start(new MediaProjection());throw new AssertionError("old Android accepted");}catch(IllegalStateException expected){}android.os.Build.VERSION.SDK_INT=34;
MediaProjection projection=new MediaProjection();capture.start(projection);check(capture.isConfigured(),"same screen projection configured");
capture.onBuffer(frame,2,1,48000,0,0);AudioRecord record=AudioRecord.instances.get(0);
check(record.configuration.projection==projection,"screen token reused without second projection");
check(record.configuration.usages.equals(new HashSet<>(Arrays.asList(0,1,14))),"only capturable media/game/unknown playback selected");
check(record.starts==1&&record.bufferSize>=3840,"capture starts once with bounded PCM buffering");
check(frame.get(0)==1&&frame.get(959)==(byte)960,"recorded PCM reaches WebRTC direct buffer");
AudioRecord.nextRead=17;capture.onBuffer(frame,2,1,48000,0,0);check(frame.get(16)==17&&frame.get(17)==0&&frame.get(959)==0,"short read pads silence rather than old audio");
capture.stop();capture.stop();check(record.stops==1&&record.releases==1&&!capture.isConfigured(),"stop is idempotent and releases loopback");
capture.start(projection);AudioRecord.nextRead=-3;capture.onBuffer(frame,2,1,48000,0,0);record=AudioRecord.instances.get(1);
check(failures[0]==1&&record.stops==1&&record.releases==1&&!capture.isConfigured(),"read failure reports track end and releases capture");
capture.onBuffer(frame,2,1,48000,0,0);check(failures[0]==1,"failure only reported once");
capture.start(projection);AudioRecord.failBuild=true;capture.onBuffer(frame,2,1,48000,0,0);check(failures[0]==2&&!capture.isConfigured(),"permission loss fails closed");
capture.start(projection);AudioRecord.failStart=true;capture.onBuffer(frame,2,1,48000,0,0);record=AudioRecord.instances.get(2);check(failures[0]==3&&record.releases==1,"failed start releases AudioRecord");
capture.start(projection);AudioRecord.blockNextRead=true;
Thread reader=new Thread(()->capture.onBuffer(frame,2,1,48000,0,0));reader.start();
while(AudioRecord.instances.size()<4)Thread.sleep(1);record=AudioRecord.instances.get(3);check(record.entered.await(2,TimeUnit.SECONDS),"read entered");
capture.stop();reader.join(2000);check(!reader.isAlive()&&record.stops==1&&record.releases==1,"stop unblocks a concurrent read and releases after its last owner");check(failures[0]==3,"normal stop does not publish a failure");
capture.start(projection);capture.onBuffer(frame,2,2,48000,0,0);record=AudioRecord.instances.get(4);capture.onBuffer(frame,2,1,48000,0,0);check(failures[0]==4&&record.releases==1,"format changes do not reinterpret stale PCM");
capture.start(projection);capture.onBuffer(frame,2,1,44100,0,0);capture.stop();check(AudioRecord.instances.get(5).releases==1,"restart supports native device sample rates");
System.out.println("Android playback audio: PCM, supported usages, consent/version, errors, concurrent stop and restart passed.");
}}
'''


def main():
    plugin = Path(__file__).resolve().parents[2]
    source = plugin / 'android/src/main/java/com/cloudwebrtc/webrtc/audio/PlaybackAudioCapture.java'
    with tempfile.TemporaryDirectory(prefix='bshare-playback-capture-') as temporary:
        root = Path(temporary)
        files = []
        for name, content in STUBS.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            files.append(str(target))
        test = root / 'PlaybackAudioCaptureTest.java'
        test.write_text(HARNESS)
        subprocess.run(['javac', '-d', str(root), *files, str(source), str(test)], check=True)
        subprocess.run(['java', '-ea', '-cp', str(root), 'PlaybackAudioCaptureTest'], check=True, timeout=15)


if __name__ == '__main__':
    main()
