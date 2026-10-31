#!/usr/bin/env python3
"""Exercise production Android torch helpers without a camera or Flutter build.

The production methods are compiled unchanged against Java camera/looper doubles.
They model an opening or closed capture session, a terminated camera thread and
late work after a timeout. A JDK with javac/java is the only prerequisite.
"""

from pathlib import Path
import subprocess,tempfile

def definition(source, signature):
 start=source.index(signature)
 cursor=source.index('{',start)
 depth=1
 end=cursor+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}')
  end+=1
 return source[start:end]

HARNESS=r'''
import java.lang.reflect.Field;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class CameraTorchTest {
 @interface RequiresApi { int api(); }
 static class Build { static class VERSION { static int SDK_INT=36; } static class VERSION_CODES { static final int LOLLIPOP=21; } }
 static class Looper { static final Looper MAIN=new Looper(); static Looper getMainLooper(){return MAIN;} }
 static class Handler {
  static final List<Runnable> delayed=new ArrayList<>();
  final List<Runnable> queued=new ArrayList<>();
  boolean closed;
  Handler(){} Handler(Looper looper){}
  boolean post(Runnable task){if(closed)return false;queued.add(task);return true;}
  boolean postDelayed(Runnable task,long duration){delayed.add(task);return true;}
  void removeCallbacks(Runnable task){delayed.remove(task);queued.remove(task);}
  void drain(){List<Runnable> jobs=new ArrayList<>(queued);queued.clear();for(Runnable job:jobs){onCameraThread=true;try{job.run();}finally{onCameraThread=false;}}}
  static void timeout(){List<Runnable> jobs=new ArrayList<>(delayed);delayed.clear();jobs.forEach(Runnable::run);}
 }
 static boolean onCameraThread;
 static class MethodChannel { interface Result { void success(Object value); void error(String code,String message,Object details); void notImplemented(); } }
 static class AnyThreadResult implements MethodChannel.Result {
  final MethodChannel.Result delegate; AnyThreadResult(MethodChannel.Result result){delegate=result;}
  public void success(Object value){delegate.success(value);} public void error(String code,String message,Object details){delegate.error(code,message,details);} public void notImplemented(){delegate.notImplemented();}
 }
 static class Result implements MethodChannel.Result {
  int calls; Object value; String error;
  public void success(Object value){calls++;this.value=value;}
  public void error(String code,String message,Object details){calls++;error=message;}
  public void notImplemented(){calls++;error="not implemented";}
 }
 static class Log { static void d(String tag,String message){} }
 static class Surface {}
 static class Range<T> { Range(T min,T max){} }
 static class CameraAccessException extends Exception { CameraAccessException(){super("camera access denied");} }
 static class CameraCharacteristics {
  static final String FLASH_INFO_AVAILABLE="flash";
  Boolean flash=true;
  Boolean get(String key){return flash;}
 }
 static class CameraManager {
  final CameraCharacteristics characteristics=new CameraCharacteristics(); String requestedCamera;
  CameraCharacteristics getCameraCharacteristics(String cameraName) throws CameraAccessException {requestedCamera=cameraName;return characteristics;}
 }
 static class CaptureRequest {
  static final String FLASH_MODE="flash",CONTROL_AE_TARGET_FPS_RANGE="fps",CONTROL_AE_MODE="ae",CONTROL_AE_LOCK="aeLock";
  static final int FLASH_MODE_TORCH=2, FLASH_MODE_OFF=0, CONTROL_AE_MODE_ON=1;
  int flash;
  static class Builder {
   final CaptureRequest request=new CaptureRequest();
   void set(String key,Object value){if(key.equals(FLASH_MODE))request.flash=(int)value;}
   void addTarget(Surface surface){} CaptureRequest build(){return request;}
  }
 }
 static class CameraDevice { static final int TEMPLATE_RECORD=3; CaptureRequest.Builder createCaptureRequest(int template) throws CameraAccessException{return new CaptureRequest.Builder();} }
 static class CameraCaptureSession {
  int calls; int flash; boolean closed;
  void setRepeatingRequest(CaptureRequest request,Object callback,Handler handler) throws CameraAccessException {
   check(onCameraThread,"torch request must run on camera thread");
   if(closed)throw new IllegalStateException("session closed");calls++;flash=request.flash;
  }
 }
 static class CameraEnumerationAndroid { static class CaptureFormat { final FrameRate framerate=new FrameRate(); } static class FrameRate {int min=15000,max=30000;} }
 static class Camera {
  Parameters parameters=new Parameters(); int sets;
  Parameters getParameters(){check(onCameraThread||!parameters.requireCameraThread,"Camera1 parameters thread");return parameters;}
  void setParameters(Parameters parameters){check(onCameraThread,"Camera1 torch thread");sets++;}
  static class Parameters {
   static final String FLASH_MODE_TORCH="torch",FLASH_MODE_OFF="off";
   boolean requireCameraThread; String mode;
   List<String> getSupportedFlashModes(){return Arrays.asList(FLASH_MODE_OFF,FLASH_MODE_TORCH);}
   void setFlashMode(String mode){this.mode=mode;}
  }
 }
 static class CameraCapturer {
  private Handler cameraThreadHandler=new Handler();
  private Object currentSession;
  private String cameraName="rear";
 }
 static class Camera2Capturer extends CameraCapturer { private final CameraManager cameraManager=new CameraManager(); }
 static class Camera1Capturer extends CameraCapturer {}
 static class VideoCapturerInfo { Object capturer; }
 static class GetUserMediaImpl {
  final Map<String,VideoCapturerInfo> tracks=new HashMap<>();
  VideoCapturerInfo getCapturerInfo(String id){return tracks.get(id);}
 }
 static class Camera2Session {
  private final CameraCaptureSession captureSession=new CameraCaptureSession();
  private final CameraDevice cameraDevice=new CameraDevice();
  private final CameraEnumerationAndroid.CaptureFormat captureFormat=new CameraEnumerationAndroid.CaptureFormat();
  private final int fpsUnitFactor=1000;
  private final Surface surface=new Surface();
  private final Handler cameraThreadHandler;
  Camera2Session(Handler handler){cameraThreadHandler=handler;}
 }
 static class Camera1Session { private final Camera camera=new Camera(); }
 static class CameraUtils {
  private static final String TAG="camera-test";
  private final GetUserMediaImpl getUserMediaImpl;
  boolean isTorchOn;
  final CaptureControlsDouble captureControls=new CaptureControlsDouble();
  CameraUtils(GetUserMediaImpl media){getUserMediaImpl=media;}
  // PRODUCTION_HAS_TORCH
  // PRODUCTION_SET_TORCH
  // PRODUCTION_SET_TORCH_THREAD
  // PRODUCTION_REFLECT_EXCEPTION
  // PRODUCTION_ERROR
  // PRODUCTION_REFLECT
 }
 static class CaptureControlsDouble {
  boolean hasState(VideoCapturerInfo info){return false;}
  void setTorchOnCameraThread(String trackId,VideoCapturerInfo info,boolean torch,MethodChannel.Result result){throw new AssertionError("unexpected merged-control path in legacy torch fixture");}
 }
 static int scenarios;
 static void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
 static Result probe(CameraUtils utils){Result result=new Result();utils.hasTorch("track",result);return result;}
 static Result set(CameraUtils utils,boolean active){Result result=new Result();utils.setTorch("track",active,result);return result;}
 static void resultOnce(Result result,boolean success){check(result.calls==1,"exactly one reply");check((result.error==null)==success,"reply success state: "+result.error);}
 public static void main(String[] args) {
  GetUserMediaImpl media=new GetUserMediaImpl();CameraUtils utils=new CameraUtils(media);
  Result missing=probe(utils);resultOnce(missing,false);scenarios++;
  VideoCapturerInfo info=new VideoCapturerInfo();Camera2Capturer camera=new Camera2Capturer();info.capturer=camera;media.tracks.put("track",info);
  CameraCapturer base=camera;Handler thread=base.cameraThreadHandler;
  Result initial=probe(utils);resultOnce(initial,true);check(initial.value.equals(true),"flash available before first frame");check(camera.cameraManager.requestedCamera.equals("rear"),"camera name selection");scenarios++;
  camera.cameraManager.characteristics.flash=null;Result unknown=probe(utils);resultOnce(unknown,true);check(unknown.value.equals(false),"nullable flash capability");scenarios++;
  camera.cameraManager.characteristics.flash=true;
  Result opening=set(utils,true);check(opening.calls==0,"camera-thread dispatch is asynchronous");thread.drain();resultOnce(opening,false);check(Handler.delayed.isEmpty(),"opening error cancels timeout");scenarios++;
  Camera2Session session=new Camera2Session(thread);base.currentSession=session;
  Result enable=set(utils,true);check(session.captureSession.calls==0,"no request before camera thread");thread.drain();resultOnce(enable,true);check(session.captureSession.flash==CaptureRequest.FLASH_MODE_TORCH,"torch on");check(utils.isTorchOn,"logical torch state");check(Handler.delayed.isEmpty(),"success cancels timeout");scenarios++;
  Result disable=set(utils,false);thread.drain();resultOnce(disable,true);check(session.captureSession.flash==CaptureRequest.FLASH_MODE_OFF,"torch off");scenarios++;
  Result closing=set(utils,true);base.currentSession=null;thread.drain();resultOnce(closing,false);check(Handler.delayed.isEmpty(),"closing error cancels timeout");scenarios++;
  base.currentSession=session;thread.closed=true;Result dead=set(utils,true);resultOnce(dead,false);check(Handler.delayed.isEmpty(),"rejected post cancels timeout");scenarios++;
  thread.closed=false;int requests=session.captureSession.calls;Result timeout=set(utils,true);Handler.timeout();resultOnce(timeout,false);thread.drain();resultOnce(timeout,false);check(session.captureSession.calls==requests,"timed-out command must not turn flash on later");scenarios++;
  session.captureSession.closed=true;Result closed=set(utils,true);thread.drain();resultOnce(closed,false);check(Handler.delayed.isEmpty(),"closed session cancels timeout");scenarios++;
  Camera1Capturer old=new Camera1Capturer();info.capturer=old;Result oldOpening=probe(utils);resultOnce(oldOpening,false);scenarios++;
  Camera1Session oldSession=new Camera1Session();CameraCapturer oldBase=old;oldBase.currentSession=oldSession;Result oldCapability=probe(utils);resultOnce(oldCapability,true);check(oldCapability.value.equals(true),"Camera1 torch capability");oldSession.camera.parameters.requireCameraThread=true;Result oldEnable=set(utils,true);oldBase.cameraThreadHandler.drain();resultOnce(oldEnable,true);check(oldSession.camera.sets==1,"Camera1 torch writes once");check(Handler.delayed.isEmpty(),"all timeouts removed");scenarios++;
  System.out.println("Android torch: "+scenarios+" capability/session/thread/timeout/late-command scenarios passed.");
 }
}
'''

def main():
    plugin = Path(__file__).resolve().parents[2]
    source = (plugin / 'android/src/main/java/com/cloudwebrtc/webrtc/'
              'video/camera/CameraUtils.java').read_text()
    java = HARNESS
    methods = [
        ('HAS_TORCH', 'public void hasTorch('),
        ('SET_TORCH', 'public void setTorch('),
        ('SET_TORCH_THREAD', 'private void setTorchOnCameraThread('),
        ('REFLECT_EXCEPTION', 'private class NoSuchFieldWithNameException'),
        ('ERROR', 'static private void resultError('),
        ('REFLECT', 'private Object getPrivateProperty('),
    ]
    for marker, signature in methods:
        java = java.replace('// PRODUCTION_' + marker + '\n',
                            definition(source, signature) + '\n')
    with tempfile.TemporaryDirectory(prefix='bshare-camera-torch-') as directory:
        temp = Path(directory)
        test_source = temp / 'CameraTorchTest.java'
        test_source.write_text(java)
        subprocess.run(['javac', '-Xlint:unchecked', '-d', str(temp),
                        str(test_source)], check=True)
        subprocess.run(['java', '-ea', '-cp', str(temp), 'CameraTorchTest'],
                       check=True)


if __name__ == '__main__':
    main()
