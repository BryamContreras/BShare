#!/usr/bin/env python3
"""Run the production Android renderer with EGL/producer/event doubles."""
from pathlib import Path
import os
import subprocess
import tempfile

STUBS = {
    'android/graphics/SurfaceTexture.java': 'package android.graphics;public class SurfaceTexture {}',
    'android/view/Surface.java': 'package android.view;public class Surface {}',
    'org/webrtc/EglBase.java': 'package org.webrtc;public interface EglBase {int[] CONFIG_PLAIN=new int[0];interface Context {}}',
    'org/webrtc/RendererCommon.java': '''package org.webrtc;public class RendererCommon {public interface GlDrawer {}public interface RendererEvents {void onFirstFrameRendered();void onFrameResolutionChanged(int width,int height,int rotation);}}''',
    'org/webrtc/GlRectDrawer.java': 'package org.webrtc;public class GlRectDrawer implements RendererCommon.GlDrawer {}',
    'org/webrtc/VideoFrame.java': '''package org.webrtc;public class VideoFrame {int width,height,rotation;public VideoFrame(int w,int h,int r){width=w;height=h;rotation=r;}public int getRotatedWidth(){return rotation%180==0?width:height;}public int getRotatedHeight(){return rotation%180==0?height:width;}public int getRotation(){return rotation;}public Buffer getBuffer(){return new Buffer();}public class Buffer {public int getWidth(){return width;}public int getHeight(){return height;}}}''',
    'org/webrtc/ThreadUtils.java': '''package org.webrtc;public class ThreadUtils {public static void checkIsOnMainThread(){}public static void awaitUninterruptibly(java.util.concurrent.CountDownLatch latch){try{latch.await();}catch(InterruptedException e){throw new AssertionError(e);}}}''',
    'org/webrtc/EglRenderer.java': '''package org.webrtc;public class EglRenderer {public int draws,surfaces,releases;boolean initialized;public EglRenderer(String name){}public void init(EglBase.Context context,int[] attributes,RendererCommon.GlDrawer drawer){initialized=true;}public void release(){initialized=false;}public void createEglSurface(android.view.Surface surface){if(!initialized)throw new AssertionError("EGL creation after release");surfaces++;}public void releaseEglSurface(Runnable done){releases++;done.run();}public void onFrame(VideoFrame frame){if(!initialized)throw new AssertionError("draw after release");draws++;}public void setFpsReduction(float fps){}public void disableFpsReduction(){}public void pauseVideo(){}}''',
    'io/flutter/view/TextureRegistry.java': '''package io.flutter.view;public interface TextureRegistry {interface SurfaceProducer {void setSize(int width,int height);android.view.Surface getSurface();void setCallback(Callback callback);interface Callback {void onSurfaceAvailable();void onSurfaceCleanup();}}}''',
}

HARNESS = r'''
import com.cloudwebrtc.webrtc.SurfaceTextureRenderer;
import org.webrtc.*;import io.flutter.view.TextureRegistry;
public class HiddenScreenRendererTest {
 static class Producer implements TextureRegistry.SurfaceProducer {int sizes,width,height,gets;Callback callback;public void setSize(int w,int h){sizes++;width=w;height=h;}public android.view.Surface getSurface(){gets++;return new android.view.Surface();}public void setCallback(Callback c){callback=c;}}
 static class Events implements RendererCommon.RendererEvents {int first,changes,w,h,r;public void onFirstFrameRendered(){first++;}public void onFrameResolutionChanged(int w,int h,int r){changes++;this.w=w;this.h=h;this.r=r;}}
 static void check(boolean result,String message){if(!result)throw new AssertionError(message);}
 public static void main(String[] args){SurfaceTextureRenderer renderer=new SurfaceTextureRenderer("test");Producer producer=new Producer();Events events=new Events();renderer.init(null,events);renderer.surfaceCreated(producer);
  renderer.onFrame(new VideoFrame(640,360,0));check(renderer.draws==1&&renderer.surfaces==1&&producer.sizes==1,"normal default remains rendered");check(events.first==1&&events.changes==1,"normal metadata");
  renderer.setFrameOutputEnabled(false);renderer.onFrame(new VideoFrame(1080,2316,0));check(renderer.draws==1&&renderer.surfaces==1&&producer.sizes==1,"hidden frame does not create or draw an EGL surface");check(events.changes==2&&events.w==1080&&events.h==2316,"hidden screen dimensions still reported");
  renderer.onFrame(new VideoFrame(2316,1080,90));check(events.changes==3&&events.r==90,"hidden rotation reported");check(renderer.draws==1&&producer.gets==1,"hidden rotation does no pixel rendering");
  renderer.setFrameOutputEnabled(true);renderer.onFrame(new VideoFrame(2316,1080,90));check(renderer.draws==2&&renderer.surfaces==2&&producer.width==1080&&producer.height==2316,"reenable uses actual surface size, not dimensions already reported while hidden");check(events.changes==3,"reenable does not duplicate size events");
  renderer.onFrame(new VideoFrame(1920,1080,0));check(renderer.draws==3&&renderer.surfaces==3&&events.changes==4,"normal later resizing continues");
  renderer.setFrameOutputEnabled(false);renderer.release();int changes=events.changes,surfaces=renderer.surfaces;renderer.onFrame(new VideoFrame(320,180,0));check(events.changes==changes&&renderer.surfaces==surfaces,"disposed renderer ignores late frame");boolean rejected=false;try{renderer.setFrameOutputEnabled(true);}catch(IllegalStateException expected){rejected=true;}check(rejected,"disposed output flag guarded");
  renderer.init(null,events);renderer.surfaceCreated(producer);renderer.onFrame(new VideoFrame(320,180,0));check(renderer.draws==3&&renderer.surfaces==surfaces,"hidden flag survives source reinitialization");check(events.first==2&&events.w==320,"new hidden source still reports first frame and metadata");renderer.setFrameOutputEnabled(true);renderer.onFrame(new VideoFrame(320,180,0));check(renderer.draws==4&&renderer.surfaces==surfaces+1&&producer.width==320,"camera reenable after release recreates EGL even with unchanged reported dimensions");
  producer.callback.onSurfaceCleanup();renderer.onFrame(new VideoFrame(320,180,0));check(renderer.surfaces==surfaces+2,"producer cleanup recreates next visible surface");renderer.release();System.out.println("Hidden Android renderer: default, no hidden EGL/draw, metadata/rotation, reenable/resize, source reuse and dispose checks passed.");
 }
}
'''

def main():
    plugin = Path(__file__).resolve().parents[2]
    source = plugin / 'android/src/main/java/com/cloudwebrtc/webrtc/SurfaceTextureRenderer.java'
    with tempfile.TemporaryDirectory(prefix='bshare-hidden-renderer-') as directory:
        temp = Path(directory)
        for name, text in STUBS.items():
            path = temp / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        harness = temp / 'HiddenScreenRendererTest.java'
        harness.write_text(HARNESS)
        java_home = os.environ.get('JAVA_HOME')
        candidates = [Path(java_home) / 'bin' if java_home else None,
                      Path('C:/Program Files/Android/Android Studio/jbr/bin')]
        java_bin = next((path for path in candidates if path and (path / 'javac.exe').exists()), None)
        javac = str(java_bin / 'javac.exe') if java_bin else 'javac'
        java = str(java_bin / 'java.exe') if java_bin else 'java'
        subprocess.run([javac, '-d', str(temp), str(source),
                        *[str(temp / name) for name in STUBS], str(harness)], check=True)
        subprocess.run([java, '-ea', '-cp', str(temp), 'HiddenScreenRendererTest'], check=True)

if __name__ == '__main__':
    main()
