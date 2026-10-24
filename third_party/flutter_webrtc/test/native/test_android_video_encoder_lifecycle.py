#!/usr/bin/env python3
"""Exercise the production Java encoder wrapper with actual worker threads.

Checks thread retirement/reuse, interruption, and scaled frame ownership. This
does not model vendor MediaCodec implementations or measure video performance.
"""

from pathlib import Path
import subprocess
import tempfile


STUBS = {
    "org/webrtc/VideoCodecStatus.java": """
package org.webrtc; public enum VideoCodecStatus { OK, ERROR }
""",
    "org/webrtc/VideoEncoder.java": """
package org.webrtc;
public interface VideoEncoder {
  class Settings { public final int width,height; public Settings(int w,int h){width=w;height=h;} }
  interface Callback {}
  class EncodeInfo {}
  class BitrateAllocation {}
  class ScalingSettings {}
  class RateControlParameters {}
  class ResolutionBitrateLimits {}
  class EncoderInfo {}
  VideoCodecStatus initEncode(Settings settings,Callback callback);
  VideoCodecStatus release();
  VideoCodecStatus encode(VideoFrame frame,EncodeInfo info);
  VideoCodecStatus setRateAllocation(BitrateAllocation allocation,int fps);
  ScalingSettings getScalingSettings();
  String getImplementationName();
  long createNative(long reference);
  boolean isHardwareEncoder();
  VideoCodecStatus setRates(RateControlParameters parameters);
  ResolutionBitrateLimits[] getResolutionBitrateLimits();
  EncoderInfo getEncoderInfo();
}
""",
    "org/webrtc/VideoFrame.java": """
package org.webrtc;
public class VideoFrame {
  public interface Buffer {
    int getWidth(); int getHeight();
    Buffer cropAndScale(int x,int y,int w,int h,int targetWidth,int targetHeight);
    void release();
  }
  final Buffer buffer; final int rotation; final long timestamp;
  public VideoFrame(Buffer b,int r,long t){buffer=b;rotation=r;timestamp=t;}
  public Buffer getBuffer(){return buffer;}
  public int getRotation(){return rotation;}
  public long getTimestampNs(){return timestamp;}
  public void release(){buffer.release();}
}
""",
}

HARNESS = r"""
package com.cloudwebrtc.webrtc;
import org.webrtc.*;
import java.util.*;
import java.util.concurrent.*;

public class AndroidVideoEncoderLifecycleTest {
  static int checks;
  static synchronized void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
  static class Buffer implements VideoFrame.Buffer {
    final int width,height;
    int releases; Buffer adapted;
    Buffer(int w,int h){width=w;height=h;}
    public int getWidth(){return width;}
    public int getHeight(){return height;}
    public Buffer cropAndScale(int x,int y,int w,int h,int tw,int th){
      check(x==0&&y==0&&w==width&&h==height,"preserve whole frame");
      return adapted=new Buffer(tw,th);
    }
    public void release(){check(++releases==1,"buffer released once");}
  }
  static class Encoder implements VideoEncoder {
    final List<Thread> workers=new ArrayList<>(); Thread worker;
    boolean failEncode,failRelease;
    int releases,frames,width,height;
    CountDownLatch entered,proceed;
    void sameThread(){check(Thread.currentThread()==worker,"encoder thread affinity");}
    public VideoCodecStatus initEncode(Settings settings,Callback callback){
      check(worker==null,"previous session released");
      worker=Thread.currentThread();workers.add(worker);return VideoCodecStatus.OK;
    }
    public VideoCodecStatus release(){sameThread();worker=null;releases++;
      if(failRelease){failRelease=false;throw new IllegalStateException("release failure");}
      return VideoCodecStatus.OK;
    }
    public VideoCodecStatus encode(VideoFrame frame,EncodeInfo info){
      sameThread();width=frame.getBuffer().getWidth();height=frame.getBuffer().getHeight();
      check(frame.getRotation()==90&&frame.getTimestampNs()==123,"preserve frame metadata");
      if(entered!=null){entered.countDown();try{proceed.await();}catch(InterruptedException e){throw new AssertionError(e);}}
      if(failEncode)throw new IllegalStateException("encode failure");
      frames++;return VideoCodecStatus.OK;
    }
    public VideoCodecStatus setRateAllocation(BitrateAllocation a,int f){sameThread();return VideoCodecStatus.OK;}
    public ScalingSettings getScalingSettings(){sameThread();return new ScalingSettings();}
    public String getImplementationName(){return "test encoder";}
    public long createNative(long ref){sameThread();return 0;}
    public boolean isHardwareEncoder(){sameThread();return true;}
    public VideoCodecStatus setRates(RateControlParameters p){sameThread();return VideoCodecStatus.OK;}
    public ResolutionBitrateLimits[] getResolutionBitrateLimits(){sameThread();return new ResolutionBitrateLimits[0];}
    public EncoderInfo getEncoderInfo(){sameThread();return new EncoderInfo();}
  }
  static void retired(Encoder encoder)throws Exception {
    for(Thread worker:encoder.workers){worker.join(2000);check(!worker.isAlive(),"encoder worker terminated");}
  }
  static VideoFrame frame(Buffer b){return new VideoFrame(b,90,123);}
  public static void main(String[] args)throws Exception {
    Encoder nativeEncoder=new Encoder();ThreadedVideoEncoder wrapper=new ThreadedVideoEncoder(nativeEncoder);
    wrapper.release();check(nativeEncoder.releases==0,"unused wrapper needs no native release");
    wrapper.initEncode(new VideoEncoder.Settings(640,480),null);
    Buffer same=new Buffer(640,480);wrapper.encode(frame(same),null);
    check(same.adapted==null&&same.releases==0,"borrow matching frame");
    Buffer taller=new Buffer(640,960);wrapper.encode(frame(taller),null);
    check(nativeEncoder.width==640&&nativeEncoder.height==480,"height-only mismatch must scale");
    check(taller.adapted.releases==1&&taller.releases==0,"release scaled frame only");
    nativeEncoder.failEncode=true;Buffer failing=new Buffer(1280,720);
    try{wrapper.encode(frame(failing),null);throw new AssertionError("expected failure");}
    catch(IllegalStateException expected){check(expected.getMessage().equals("encode failure"),"preserve failure cause");}
    check(failing.adapted.releases==1&&failing.releases==0,"release scaled frame after encode failure");
    nativeEncoder.failEncode=false;
    wrapper.setRateAllocation(null,30);wrapper.getScalingSettings();wrapper.createNative(0);
    wrapper.isHardwareEncoder();wrapper.setRates(null);wrapper.getResolutionBitrateLimits();wrapper.getEncoderInfo();
    wrapper.release();retired(nativeEncoder);wrapper.release();
    check(nativeEncoder.releases==1,"release idempotent");
    wrapper.getImplementationName();retired(nativeEncoder);
    for(int i=0;i<8;i++){
      wrapper.initEncode(new VideoEncoder.Settings(320,240),null);
      wrapper.encode(frame(new Buffer(640,480)),null);
      wrapper.release();retired(nativeEncoder);
    }
    wrapper.initEncode(new VideoEncoder.Settings(640,480),null);nativeEncoder.failRelease=true;
    try{wrapper.release();throw new AssertionError("expected release failure");}
    catch(IllegalStateException expected){}
    retired(nativeEncoder);
    wrapper.initEncode(new VideoEncoder.Settings(640,480),null);
    nativeEncoder.entered=new CountDownLatch(1);nativeEncoder.proceed=new CountDownLatch(1);
    List<Throwable> failures=new ArrayList<>();
    Thread caller=new Thread(()->{
      try{
        Thread.currentThread().interrupt();wrapper.encode(frame(new Buffer(640,480)),null);
        check(Thread.currentThread().isInterrupted(),"restore caller interruption");
      }catch(Throwable error){failures.add(error);}
    });caller.start();
    check(nativeEncoder.entered.await(2,TimeUnit.SECONDS),"worker entered encode");
    check(caller.isAlive(),"interrupted caller must wait until buffer is no longer borrowed");
    nativeEncoder.proceed.countDown();caller.join(2000);
    check(!caller.isAlive()&&failures.isEmpty(),"interrupted encode finishes safely");
    wrapper.release();retired(nativeEncoder);
    System.out.println("Android video encoder lifecycle: "+checks+" checks passed");
  }
}
"""


def main():
    plugin = Path(__file__).resolve().parents[2]
    production = plugin / "android/src/main/java/com/cloudwebrtc/webrtc/ThreadedVideoEncoder.java"
    with tempfile.TemporaryDirectory(prefix="bshare-encoder-lifecycle-") as directory:
        work = Path(directory)
        for name, source in STUBS.items():
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source, encoding="utf-8")
        (work / "AndroidVideoEncoderLifecycleTest.java").write_text(HARNESS, encoding="utf-8")
        sources = [str(path) for path in work.rglob("*.java")]
        subprocess.run(["javac", "-d", directory, *sources, str(production)], check=True, timeout=60)
        subprocess.run(["java", "-ea", "-cp", directory,
                        "com.cloudwebrtc.webrtc.AndroidVideoEncoderLifecycleTest"], check=True, timeout=20)


if __name__ == "__main__":
    main()
