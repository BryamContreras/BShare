#!/usr/bin/env python3
"""Exercise the production Android recording gate's lifecycle and failure paths.

Production Java methods are compiled unchanged against peer/factory doubles. The
SDK model follows its virtual device, cached JNI buffer and reader START callback
before ADC acquisition. Checks cover first permission, reconnects, repeated ON,
factory-wide disable, setter/peer rollback and failed peer creation cleanup.
A JDK with javac/java is required; no device or Gradle build is used.
"""

from pathlib import Path
import re
import subprocess
import tempfile


def definition(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start)
    depth = 1
    end = cursor + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


HARNESS = r'''
import java.util.*;

public class AndroidAudioRecordingGateTest {
 static class Result {
  int calls; String error;
  void success(Object value){calls++;}
  void error(String code,String message,Object details){calls++;error=message;}
 }
 static class Log {
  static void w(String tag,String message,Throwable error){}
  static void d(String tag,String message){}
 }
 static class ConstraintsMap {}
 static class RTCConfiguration {}
 // Models SDK 144's shared ADM, including unconditional InitRecording on SDP,
 // the cached JNI buffer, and START callback before the virtual reader loop.
 static class JavaAudioDeviceModule {
  final Gate owner;
  boolean useAudioRecord=true, permission=true, initialized, nativeInitCalled;
  boolean nativeRecording, readerRunning, hardwarePrepared, hardwareActive;
  boolean failNextSet;
  int buffer, cachedBuffer, senders, hardwareOpens, illegalInitAttempts;
  int stopRequests, prewarmCalls, manualStartRequests, readerStarts, readerStops;
  JavaAudioDeviceModule(Gate owner){this.owner=owner;}
  void setAudioRecordEnabled(boolean enabled){
   if(failNextSet){failNextSet=false;throw new IllegalStateException("injected device setter failure");}
   useAudioRecord=enabled;
  }
  boolean initRecording(){
   if(initialized)return true;
   if(nativeInitCalled)return false; // Failed initial permission poisons retry.
   nativeInitCalled=true;cachedBuffer=++buffer;
   if(useAudioRecord&&!openHardware())return false;
   initialized=true;return true;
  }
  boolean openHardware(){
   if(!permission){illegalInitAttempts++;return false;}
   hardwarePrepared=true;hardwareOpens++;return true;
  }
  void startNative(){
   if(nativeRecording)return;
   if(!initRecording())return;
   check(!Thread.holdsLock(owner.audioRecordingStateLock),"state lock held over native start");
   // SDK startRecordingImpl asserts a real AudioRecord exists if use=true.
   if(useAudioRecord&&!hardwarePrepared)throw new IllegalStateException("real device missing at start");
   readerRunning=true;nativeRecording=true;readerStarts++;
   owner.onAudioRecordingStarted(); // Public callback precedes acquisition loop.
   readerCycle();
  }
  void readerCycle(){
   if(!readerRunning)return;
   check(cachedBuffer==buffer,"JNI direct buffer must not be replaced by prewarm");
   if(useAudioRecord&&!hardwarePrepared&&!openHardware()){useAudioRecord=false;return;}
   hardwareActive=useAudioRecord&&hardwarePrepared;
  }
  void stopNative(){
   check(!Thread.holdsLock(owner.audioRecordingStateLock),"state lock held over native stop/join");
   if(!initialized||!nativeRecording)return;
   nativeInitCalled=false;nativeRecording=false;initialized=false;
   stopReader();cachedBuffer=0;
  }
  void stopReader(){
   if(readerRunning){readerRunning=false;readerStops++;owner.onAudioRecordingStopped();}
   hardwareActive=false;hardwarePrepared=false;
  }
  void requestStopRecording(){
   check(!Thread.holdsLock(owner.audioRecordingStateLock),"state lock held over request stop/join");
   stopRequests++;
   if(!nativeRecording)stopReader();
  }
 }
 static class PeerConnection {
  final JavaAudioDeviceModule module;
  boolean disposed,sending,failEnable,failDisable,failOnce,failRollbackSetter;
  final List<Boolean> recordingCalls=new ArrayList<>();
  PeerConnection(JavaAudioDeviceModule module){this.module=module;}
  void setAudioRecording(boolean enabled){
   if(disposed)throw new IllegalStateException("peer disposed");
   recordingCalls.add(enabled);
   if((enabled&&failEnable)||(!enabled&&failDisable)){
    if(failOnce){failEnable=false;failDisable=false;}
    if(failRollbackSetter)module.failNextSet=true;
    throw new IllegalStateException("injected peer gate failure");
   }
   if(enabled&&module.senders>0)module.startNative();
   if(!enabled)module.stopNative();
  }
  void negotiate(){
   sending=true;module.senders++;
   // m144 VoiceChannel may initialize even when AudioState recording is false.
   if(module.initRecording()&&module.owner.audioRecordingEnabled)module.startNative();
  }
  void dispose(){
   if(sending){sending=false;if(--module.senders==0)module.stopNative();}
   disposed=true;
  }
 }
 static class PeerConnectionObserver {
  static int attachedHandlers;
  PeerConnection peer;
  PeerConnectionObserver(RTCConfiguration configuration,Object state,Object messenger,String id){attachedHandlers++;}
  void setPeerConnection(PeerConnection peer){this.peer=peer;}
  PeerConnection getPeerConnection(){return peer;}
  void dispose(){if(peer!=null)peer.dispose();attachedHandlers--;}
 }
 static class Factory {
  final JavaAudioDeviceModule module;PeerConnection next;
  Factory(JavaAudioDeviceModule module){this.module=module;}
  PeerConnection createPeerConnection(Object config,Object constraints,Object observer){PeerConnection peer=next;next=null;return peer!=null?peer:new PeerConnection(module);}
 }
 static class Gate {
  static final String TAG="test";
  final Map<String,PeerConnectionObserver> mPeerConnectionObservers=new HashMap<>();
  final JavaAudioDeviceModule audioDeviceModule=new JavaAudioDeviceModule(this);
  final Factory mFactory=new Factory(audioDeviceModule);
  final Object messenger=new Object();int sequence;
  // PRODUCTION_RECORDING_STATE
  // PRODUCTION_RECORDING_LOCK
  // PRODUCTION_RECORDING_MANAGED
  // PRODUCTION_RECORDING_THREAD
  String getNextStreamUUID(){return "peer-"+(++sequence);}
  RTCConfiguration parseRTCConfiguration(ConstraintsMap configuration){return new RTCConfiguration();}
  Object parseMediaConstraints(ConstraintsMap constraints){return constraints;}
  // PRODUCTION_GATE
  // PRODUCTION_REQUESTED
  // PRODUCTION_STARTED
  // PRODUCTION_STOPPED
  // PRODUCTION_CREATE
  // PRODUCTION_ERROR
 }
 static void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
 static Result set(Gate gate,boolean enabled){Result result=new Result();gate.setAudioRecordingEnabled(enabled,result);check(result.calls==1,"one channel result");return result;}
 static PeerConnection create(Gate gate){String id=gate.peerConnectionInit(new ConstraintsMap(),new ConstraintsMap());return gate.mPeerConnectionObservers.get(id).peer;}
 static void close(Gate gate,PeerConnection peer){String id=null;for(Map.Entry<String,PeerConnectionObserver> entry:gate.mPeerConnectionObservers.entrySet())if(entry.getValue().peer==peer)id=entry.getKey();gate.mPeerConnectionObservers.remove(id).dispose();}
 public static void main(String[] args){
  int checks=0;
  Gate compatibility=new Gate();PeerConnection compatible=create(compatibility);compatible.negotiate();check(compatibility.audioDeviceModule.hardwareActive,"default plugin audio behaviour preserved without managed gate");checks++;
  set(compatibility,false);check(!compatibility.audioDeviceModule.hardwareActive,"first managed disable stops prior recording");checks++;
  Gate gate=new Gate();JavaAudioDeviceModule adm=gate.audioDeviceModule;adm.permission=false;
  check(set(gate,false).error==null,"disable before first peer");PeerConnection first=create(gate);first.negotiate();check(first.recordingCalls.equals(Arrays.asList(false)),"first peer gated before publication");check(adm.illegalInitAttempts==0&&!adm.hardwarePrepared&&!adm.readerRunning,"initial OFF must not open ADC or thread without permission");checks++;
  int initialBuffer=adm.buffer;adm.permission=true;
  check(set(gate,true).error==null,"first permission enable");check(adm.hardwareActive&&adm.readerRunning,"first grant acquires ADC through virtual reader callback");check(adm.buffer==initialBuffer&&adm.cachedBuffer==initialBuffer,"ON preserves initialized JNI buffer");checks++;
  int readerStarts=adm.readerStarts,hardwareOpens=adm.hardwareOpens;set(gate,true);check(adm.readerStarts==readerStarts&&adm.hardwareOpens==hardwareOpens&&adm.useAudioRecord,"repeated ON preserves live ADC without new callback");checks++;
  PeerConnection second=create(gate);second.negotiate();check(adm.hardwareActive&&adm.readerStarts==readerStarts&&adm.hardwareOpens==hardwareOpens,"viewer joining ON does not disable existing reader");checks++;
  check(set(gate,false).error==null,"OFF acknowledged");check(!adm.hardwareActive&&!adm.readerRunning&&!adm.useAudioRecord,"OFF releases ADC and virtual reader");check(!gate.audioRecordingThreadRunning&&adm.readerStarts==adm.readerStops,"reader callback state cleared after join");checks++;
  check(set(gate,true).error==null,"same-peer second ON");check(adm.hardwareActive&&adm.readerRunning,"same peer restarts after OFF");check(adm.cachedBuffer==adm.buffer,"restart uses current JNI buffer");checks++;
  set(gate,false);PeerConnection third=create(gate);third.negotiate();check(!adm.hardwarePrepared&&!adm.readerRunning&&adm.illegalInitAttempts==0,"viewer joining OFF stays virtual without ADC");checks++;
  second.failEnable=true;Result failedEnable=set(gate,true);check(failedEnable.error!=null&&!gate.audioRecordingEnabled&&!adm.hardwareActive&&!adm.readerRunning,"failed enable rolls shared device back OFF");checks++;
  second.failEnable=false;check(set(gate,true).error==null,"retry enable");second.failDisable=true;second.failOnce=true;
  Result failedDisable=set(gate,false);check(failedDisable.error!=null&&!gate.audioRecordingEnabled&&!adm.hardwareActive&&!adm.readerRunning,"disable failure retries and stops every owner");checks++;
  adm.failNextSet=true;Result setterFailure=set(gate,true);check(setterFailure.error!=null&&!gate.audioRecordingEnabled&&!adm.hardwareActive,"initial device setter exception returns once and fails closed");checks++;
  second.failEnable=true;second.failRollbackSetter=true;Result rollbackSetterFailure=set(gate,true);check(rollbackSetterFailure.error!=null&&!gate.audioRecordingEnabled&&!adm.hardwareActive&&adm.stopRequests>0,"rollback setter failure still visits peers and requestStop");second.failEnable=false;second.failRollbackSetter=false;checks++;
  set(gate,false);int peersBefore=gate.mPeerConnectionObservers.size(),handlersBefore=PeerConnectionObserver.attachedHandlers;
  PeerConnection rejected=new PeerConnection(adm);rejected.failDisable=true;gate.mFactory.next=rejected;
  try{create(gate);throw new AssertionError("failed peer gate accepted");}catch(IllegalStateException expected){}
  check(rejected.disposed&&gate.mPeerConnectionObservers.size()==peersBefore&&PeerConnectionObserver.attachedHandlers==handlersBefore,"failed initial peer gate releases peer and channel before publication");checks++;
  Gate noPeers=new Gate();JavaAudioDeviceModule noPeerAdm=noPeers.audioDeviceModule;noPeerAdm.permission=false;set(noPeers,false);PeerConnection cold=create(noPeers);cold.negotiate();close(noPeers,cold);check(noPeerAdm.initialized&&!noPeerAdm.readerRunning,"SDK may retain virtual buffer with no peers");noPeerAdm.permission=true;
  set(noPeers,true);check(!noPeerAdm.useAudioRecord&&!noPeerAdm.hardwareActive,"ON without peers waits for reader callback");PeerConnection later=create(noPeers);later.negotiate();check(noPeerAdm.hardwareActive&&noPeerAdm.readerRunning,"ON new peer with cached virtual buffer starts safely");checks++;
  close(noPeers,later);check(noPeers.audioRecordingEnabled&&!noPeers.audioRecordingThreadRunning&&!noPeerAdm.useAudioRecord&&!noPeerAdm.hardwareActive,"last viewer disconnect preserves ON intent but releases reader/ADC");checks++;
  PeerConnection rejoined=create(noPeers);rejoined.negotiate();check(noPeerAdm.hardwareActive&&noPeerAdm.readerRunning&&noPeers.audioRecordingEnabled,"new viewer restarts virtual reader and real ADC while ON intent persists");checks++;
  set(noPeers,false);close(noPeers,rejoined);set(noPeers,false);check(!noPeerAdm.readerRunning&&!noPeerAdm.hardwareActive&&noPeerAdm.stopRequests>=3,"full stop and no-peer disable release remaining device owners");checks++;
  check(adm.prewarmCalls==0&&adm.manualStartRequests==0&&noPeerAdm.prewarmCalls==0,"no prewarm buffer allocation or manual client-start ownership");checks++;
  System.out.println("Android audio recording gate: "+checks+" SDK144 virtual-device/callback/permission/buffer/rollback/cleanup scenarios passed.");
 }
}
'''


def main():
    plugin = Path(__file__).resolve().parents[2]
    source = (plugin / 'android/src/main/java/com/cloudwebrtc/webrtc/'
              'MethodCallHandlerImpl.java').read_text()
    java = HARNESS
    for marker, expression in [
        ('STATE', r'private boolean audioRecordingEnabled = [^;]+;'),
        ('LOCK', r'private final Object audioRecordingStateLock = [^;]+;'),
        ('MANAGED', r'private boolean audioRecordingManaged = [^;]+;'),
        ('THREAD', r'private boolean audioRecordingThreadRunning = [^;]+;'),
    ]:
        java = java.replace('// PRODUCTION_RECORDING_' + marker,
                            re.search(expression, source).group())
    for marker, signature in [
        ('GATE', 'private void setAudioRecordingEnabled('),
        ('REQUESTED', 'private void setRequestedAudioRecording('),
        ('STARTED', 'private void onAudioRecordingStarted('),
        ('STOPPED', 'private void onAudioRecordingStopped('),
        ('CREATE', 'public String peerConnectionInit('),
        ('ERROR', 'static private void resultError('),
    ]:
        java = java.replace('// PRODUCTION_' + marker + '\n',
                            definition(source, signature) + '\n')
    with tempfile.TemporaryDirectory(prefix='bshare-recording-gate-') as directory:
        temp = Path(directory)
        test_source = temp / 'AndroidAudioRecordingGateTest.java'
        test_source.write_text(java)
        subprocess.run(['javac', '-d', str(temp), str(test_source)], check=True)
        subprocess.run(['java', '-ea', '-cp', str(temp),
                        'AndroidAudioRecordingGateTest'], check=True, timeout=15)


if __name__ == '__main__':
    main()
