#!/usr/bin/env python3
"""Compile production cleanup methods against the SDK's JNI ownership model.

Tracks and streams hold independent native references; Java source wrappers must
be released explicitly. No Android process, device, or Gradle build is needed.
"""

from pathlib import Path
import subprocess
import tempfile


def definition(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start)
    depth, end = 1, cursor + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('@Override\n  ', '')


HARNESS = r'''
import java.util.*;
public class LocalMediaOwnershipTest {
 static int sources, nativeTracks, nativeStreams, rawDisposals, cases;
 static class Log {
  static void d(String tag,String msg){}
  static void w(String tag,String msg,Throwable error){}
 }
 static void check(boolean yes,String msg){if(!yes)throw new AssertionError(msg);}
 static class MediaConstraints {}
 static class AudioSource {
  int refs=1; boolean disposed;
  AudioSource(){sources++;}
  void retain(){check(refs>0,"source already released");refs++;}
  void release(){check(refs>0,"double source release");if(--refs==0)sources--;}
  void dispose(){check(!disposed,"double source wrapper disposal");disposed=true;release();}
 }
 static class NativeTrack {
  int refs=1; final AudioSource source;
  NativeTrack(AudioSource source){this.source=source;source.retain();nativeTracks++;}
  void retain(){check(refs>0,"native track already released");refs++;}
  void release(){check(refs>0,"double native track release");if(--refs==0){nativeTracks--;source.release();}}
 }
 static class MediaStreamTrack {
  final String name; final NativeTrack nativeTrack; boolean disposed,enabled=true;
  MediaStreamTrack(String id,AudioSource source){name=id;nativeTrack=new NativeTrack(source);}
  String id(){checkLive();return name;}
  void checkLive(){if(disposed)throw new IllegalStateException("disposed track");}
  void setEnabled(boolean value){checkLive();enabled=value;}
  void dispose(){checkLive();disposed=true;rawDisposals++;nativeTrack.release();}
 }
 static class AudioTrack extends MediaStreamTrack {
  AudioTrack(String id,AudioSource source){super(id,source);}
 }
 static class VideoTrack extends MediaStreamTrack {
  VideoTrack(String id,AudioSource source){super(id,source);}
 }
 static class LocalTrack {
  final MediaStreamTrack track;
  LocalTrack(MediaStreamTrack track){this.track=track;}
  void setEnabled(boolean value){track.setEnabled(value);}
 }
 static class LocalVideoTrack extends LocalTrack {
  LocalVideoTrack(VideoTrack track){super(track);}
 }
 static class MediaStream {
  final String name; boolean disposed, rejectAdd, throwAdd;
  final List<AudioTrack> audioTracks=new ArrayList<>();
  final List<VideoTrack> videoTracks=new ArrayList<>(),preservedVideoTracks=new ArrayList<>();
  final Set<NativeTrack> nativeRefs=Collections.newSetFromMap(new IdentityHashMap<NativeTrack,Boolean>());
  MediaStream(String name){this.name=name;nativeStreams++;}
  void checkLive(){if(disposed)throw new IllegalStateException("disposed stream");}
  String getId(){checkLive();return name;}
  boolean addTrack(AudioTrack track){checkLive();if(throwAdd)throw new IllegalStateException("add failed");if(rejectAdd)return false;track.checkLive();audioTracks.add(track);if(nativeRefs.add(track.nativeTrack))track.nativeTrack.retain();return true;}
  boolean addTrack(VideoTrack track){checkLive();track.checkLive();videoTracks.add(track);if(nativeRefs.add(track.nativeTrack))track.nativeTrack.retain();return true;}
  void addPreservedTrack(VideoTrack track){checkLive();track.checkLive();preservedVideoTracks.add(track);if(nativeRefs.add(track.nativeTrack))track.nativeTrack.retain();}
  boolean removeTrack(AudioTrack track){checkLive();audioTracks.remove(track);track.checkLive();boolean found=nativeRefs.remove(track.nativeTrack);if(found)track.nativeTrack.release();return found;}
  boolean removeTrack(VideoTrack track){checkLive();videoTracks.remove(track);preservedVideoTracks.remove(track);track.checkLive();boolean found=nativeRefs.remove(track.nativeTrack);if(found)track.nativeTrack.release();return found;}
  void dispose(){checkLive();while(!audioTracks.isEmpty()){AudioTrack t=audioTracks.get(0);removeTrack(t);t.dispose();}while(!videoTracks.isEmpty()){VideoTrack t=videoTracks.get(0);removeTrack(t);t.dispose();}while(!preservedVideoTracks.isEmpty())removeTrack(preservedVideoTracks.get(0));for(NativeTrack ref:nativeRefs)ref.release();nativeRefs.clear();disposed=true;nativeStreams--;}
 }
 static class PeerConnectionFactory {
  boolean failTrack, nullTrack;
  AudioSource createAudioSource(MediaConstraints constraints){return new AudioSource();}
  AudioTrack createAudioTrack(String id,AudioSource source){if(failTrack)throw new IllegalStateException("track creation failed");return nullTrack?null:new AudioTrack(id,source);}
 }
 static class Capturers {final Owner owner;int removals;Capturers(Owner owner){this.owner=owner;}void removeVideoCapturer(String id){check(!Thread.holdsLock(owner.localTracks),"local track lock held over capture stop/join");removals++;}}
 static class PeerConnectionObserver {
  final List<NativeTrack> refs=new ArrayList<>();
  void retain(MediaStreamTrack track){track.nativeTrack.retain();refs.add(track.nativeTrack);}
  void dispose(){for(NativeTrack ref:refs)ref.release();refs.clear();}
 }
 static class Owner {
  static final String TAG="test";
  final Map<String,MediaStream> localStreams=new HashMap<>();
  final Map<String,LocalTrack> localTracks=new HashMap<>();
  final Map<MediaStreamTrack,Boolean> ownedLocalTracks=new IdentityHashMap<>();
  final Map<String,PeerConnectionObserver> mPeerConnectionObservers=new HashMap<>();
  final Capturers getUserMediaImpl=new Capturers(this);
  final List<String> detached=new ArrayList<>();
  void removeStreamForRendererById(String id){for(MediaStream s:localStreams.values())if(s.name.equals(id))check(!s.disposed,"renderer detach after stream release");detached.add(id);}
  void removeTrackForRendererById(String id){}
  boolean peerConnectionDispose(PeerConnectionObserver peer){peer.dispose();return true;}
  MediaStream stream(String id){MediaStream s=new MediaStream(id);localStreams.put(id,s);return s;}
  AudioTrack audio(MediaStream s,String id){AudioTrack t=createUserAudioTrack(new PeerConnectionFactory(),new MediaConstraints(),s,id);putLocalTrack(id,new LocalTrack(t));return t;}
  VideoTrack video(MediaStream s,String id){AudioSource source=new AudioSource();VideoTrack t=new VideoTrack(id,source);source.dispose();s.addTrack(t);putLocalTrack(id,new LocalVideoTrack(t));return t;}
  // PRODUCTION_METHODS
 }
 static void clean(){check(sources==0,"source refs remain: "+sources);check(nativeTracks==0,"track refs remain: "+nativeTracks);check(nativeStreams==0,"stream refs remain: "+nativeStreams);cases++;}
 public static void main(String[] args){
  // App ordering: track.stop (including repeated stop), then stream.dispose.
  {Owner o=new Owner();MediaStream s=o.stream("s");AudioTrack t=o.audio(s,"a");o.trackDispose("a");o.trackDispose("a");check(!t.disposed,"stop must leave stream-owned wrapper alive");o.streamDispose("s");o.streamDispose("s");o.dispose();clean();}
  // Direct terminal disposal of a live audio+video stream.
  {Owner o=new Owner();MediaStream s=o.stream("s");o.audio(s,"a");o.video(s,"v");o.streamDispose("s");check(o.localTracks.isEmpty()&&o.ownedLocalTracks.isEmpty(),"terminal cleanup maps");check(o.getUserMediaImpl.removals==1,"video capture cleanup");clean();}
  // Dart clone attaches the identical wrapper to a second stream.
  {Owner o=new Owner();MediaStream a=o.stream("a"),b=o.stream("b");AudioTrack t=o.audio(a,"audio");b.addTrack(t);o.trackDispose("audio");o.streamDispose("a");check(!t.disposed,"shared wrapper disposed before last stream");o.streamDispose("b");check(t.disposed,"last stream must release shared wrapper");clean();}
  // A borrowed peer track must survive disposal of its local stream container.
  {Owner o=new Owner();MediaStream s=o.stream("s");AudioSource src=new AudioSource();AudioTrack remote=new AudioTrack("remote",src);src.dispose();s.addTrack(remote);o.localTracks.put("remote",new LocalTrack(remote));o.streamDispose("s");check(!remote.disposed,"remote wrapper belongs to peer");o.dispose();check(!remote.disposed,"engine must not double-dispose borrowed peer wrapper");remote.dispose();clean();}
  // Peer cleanup can dispose its borrowed wrapper before its local container.
  {Owner o=new Owner();MediaStream s=o.stream("s");AudioSource src=new AudioSource();AudioTrack remote=new AudioTrack("remote",src);src.dispose();s.addTrack(remote);remote.dispose();check(nativeTracks==1,"native stream still retains borrowed track");o.streamDispose("s");check(s.disposed,"dead borrowed wrapper prevented native stream release");o.dispose();clean();}
  // A sender's own native reference outlives the local Java wrapper safely.
  {Owner o=new Owner();MediaStream s=o.stream("s");AudioTrack t=o.audio(s,"a");PeerConnectionObserver peer=new PeerConnectionObserver();peer.retain(t);o.mPeerConnectionObservers.put("p",peer);o.streamDispose("s");check(t.disposed&&nativeTracks==1&&sources==1,"sender must retain native source until peer cleanup");o.dispose();clean();}
  // Engine terminal cleanup is idempotent, also for shared stream wrappers.
  {Owner o=new Owner();MediaStream a=o.stream("a"),b=o.stream("b");b.addTrack(o.audio(a,"a"));o.dispose();o.dispose();clean();}
  // Explicitly detached raw tracks have no stream owner at track.stop time.
  {Owner o=new Owner();MediaStream s=o.stream("s");AudioTrack t=o.audio(s,"a");s.removeTrack(t);o.trackDispose("a");check(t.disposed&&o.ownedLocalTracks.isEmpty(),"detached stop must release wrapper immediately");o.streamDispose("s");clean();}
  // Preserved wrappers are borrowed and follow the SDK's no-dispose contract.
  {Owner o=new Owner();MediaStream s=o.stream("s");AudioSource src=new AudioSource();VideoTrack t=new VideoTrack("external",src);src.dispose();s.addPreservedTrack(t);o.streamDispose("s");check(!t.disposed,"preserved wrapper remains borrowed");t.dispose();clean();}
  // Local wrappers in preserved lists still count as shared references.
  {Owner o=new Owner();MediaStream a=o.stream("a"),b=o.stream("b");VideoTrack t=o.video(a,"v");b.addPreservedTrack(t);o.streamDispose("a");check(!t.disposed,"preserved local reference was ignored");o.streamDispose("b");o.trackDispose("v");check(t.disposed,"detached preserved local must release on stop");o.dispose();clean();}
  // Failure cleanup releases the temporary source and any created raw track.
  for(int mode=0;mode<4;mode++){Owner o=new Owner();MediaStream s=o.stream("s");PeerConnectionFactory f=new PeerConnectionFactory();f.failTrack=mode==0;f.nullTrack=mode==1;s.rejectAdd=mode==2;s.throwAdd=mode==3;try{check(o.createUserAudioTrack(f,new MediaConstraints(),s,"a")==null,"failure should not return a track");}catch(IllegalStateException expected){check(mode==0||mode==3,"unexpected failure");}check(sources==0&&nativeTracks==0,"failed source/track not released");o.streamDispose("s");clean();}
  // Repeated live microphone allocation/stop/dispose must leave no JNI refs.
  {Owner o=new Owner();for(int i=0;i<1000;i++){MediaStream s=o.stream("mic-"+i);o.audio(s,"audio-"+i);o.trackDispose("audio-"+i);o.streamDispose(s.name);check(o.ownedLocalTracks.isEmpty()&&o.localTracks.isEmpty()&&o.localStreams.isEmpty(),"cycle "+i+" retained Java ownership");check(sources==0&&nativeTracks==0&&nativeStreams==0,"cycle "+i+" retained JNI refs");}o.dispose();clean();}
  System.out.println("PASS "+cases+" native ownership scenarios, including 1000 microphone cycles; source/track/stream JNI refs all zero");
 }
}
'''


def main():
    root = Path(__file__).resolve().parents[2]
    handler = (root / 'android/src/main/java/com/cloudwebrtc/webrtc/MethodCallHandlerImpl.java').read_text()
    media = (root / 'android/src/main/java/com/cloudwebrtc/webrtc/GetUserMediaImpl.java').read_text()
    methods = [definition(handler, signature) for signature in (
        'void dispose()',
        'public boolean putLocalTrack(',
        'public void trackDispose(',
        'public void streamDispose(final String streamId)',
        'public void streamDispose(final MediaStream stream)',
        'private boolean isTrackInLocalStream(',
        'private void disposeOwnedLocalTrack(',
    )]
    methods.append(definition(media, 'private AudioTrack createUserAudioTrack('))
    source = HARNESS.replace('// PRODUCTION_METHODS', '\n'.join(methods))
    with tempfile.TemporaryDirectory(prefix='bshare-native-ownership-') as directory:
        java = Path(directory) / 'LocalMediaOwnershipTest.java'
        java.write_text(source)
        subprocess.run(['javac', '-d', directory, str(java)], check=True)
        subprocess.run(['java', '-cp', directory, 'LocalMediaOwnershipTest'], check=True)


if __name__ == '__main__':
    main()
