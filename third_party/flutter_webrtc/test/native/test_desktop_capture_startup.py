#!/usr/bin/env python3
"""Compile desktop startup publication/rollback and OnStop unchanged.

Controlled capturers return the SDK's startup states. The tests verify that
failed capture cannot publish streams/tracks or retain its loopback session,
and that late stop callbacks cannot tear down another capture's audio.
"""

from pathlib import Path
import subprocess
import tempfile


def definition(source, signature):
    start = source.index(signature)
    cursor = source.index("{", start)
    depth, end = 1, cursor + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = r"""
#include <cassert>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <vector>
template<class T> using scoped_refptr=std::shared_ptr<T>;
struct String { std::string value; std::string std_string()const{return value;} };
struct Track { String id()const{return {name};} std::string name; };
struct Tracks { std::vector<scoped_refptr<Track>> values; auto std_vector(){return values;} };
struct Stream { Tracks tracks(){return {{{std::make_shared<Track>(Track{"video"})},
                                         {std::make_shared<Track>(Track{"audio"})}}};} };
struct Base {
  std::map<std::string,scoped_refptr<Track>> local_tracks_;
  std::map<std::string,scoped_refptr<Stream>> local_streams_;
};
struct Result {
  int errors=0,successes=0;
  void Error(const char*,const char*){errors++;}
  void Success(int){successes++;}
};
int EncodableValue(int value){return value;}
struct LoopbackCapturer {
  int* stops;
  void Stop(){++*stops;}
};
struct FlutterScreenCapture;
struct RTCDesktopCapturer {
  enum CaptureState {CS_RUNNING,CS_STOPPED,CS_FAILED};
  CaptureState outcome=CS_RUNNING;
  FlutterScreenCapture* observer=nullptr;
  int starts=0,stops=0,callbacks=0;
  CaptureState Start(uint32_t fps){assert(fps==30);starts++;return outcome;}
  void DeRegisterDesktopCapturerObserver(){observer=nullptr;}
  void Stop();
};
struct FlutterScreenCapture {
  Base ownedBase; Base* base_=&ownedBase;
  std::unique_ptr<LoopbackCapturer> loopback_capturer_;
  RTCDesktopCapturer* loopback_owner_=nullptr;
  std::shared_ptr<int> loopback_audio_source_;
  void OnStop(scoped_refptr<RTCDesktopCapturer> capturer);
  void FinishStart(scoped_refptr<RTCDesktopCapturer> desktop_capturer,
                   Result* result) {
    const double fps=30; const int params=1; const std::string uuid="stream";
    auto stream=std::make_shared<Stream>();
    // STARTUP
  }
};
// ON_STOP
void RTCDesktopCapturer::Stop(){
  stops++;
  if(observer){callbacks++;observer->OnStop(scoped_refptr<RTCDesktopCapturer>(this,[](auto*){}));}
}
void Audio(FlutterScreenCapture& owner,RTCDesktopCapturer* capturer,int& stops){
  owner.loopback_capturer_=std::make_unique<LoopbackCapturer>(LoopbackCapturer{&stops});
  owner.loopback_owner_=capturer;owner.loopback_audio_source_=std::make_shared<int>(1);
}
int main(){
  for(auto state:{RTCDesktopCapturer::CS_FAILED,RTCDesktopCapturer::CS_STOPPED}){
    FlutterScreenCapture capture;auto capturer=std::make_shared<RTCDesktopCapturer>();
    capturer->outcome=state;capturer->observer=&capture;
    int audioStops=0;Audio(capture,capturer.get(),audioStops);Result result;
    capture.FinishStart(capturer,&result);
    assert(result.errors==1&&result.successes==0);
    assert(capture.ownedBase.local_tracks_.empty()&&capture.ownedBase.local_streams_.empty());
    assert(capturer->starts==1&&capturer->stops==1&&capturer->callbacks==0);
    assert(audioStops==1&&!capture.loopback_capturer_&&!capture.loopback_audio_source_);
    assert(!capture.loopback_owner_);
    capture.OnStop(capturer);assert(audioStops==1);
  }
  {
    FlutterScreenCapture capture;auto capturer=std::make_shared<RTCDesktopCapturer>();
    capturer->observer=&capture;int audioStops=0;Audio(capture,capturer.get(),audioStops);Result result;
    capture.FinishStart(capturer,&result);
    assert(result.errors==0&&result.successes==1&&capturer->stops==0&&audioStops==0);
    assert(capture.ownedBase.local_tracks_.size()==2&&capture.ownedBase.local_streams_.size()==1);
    capturer->Stop();assert(audioStops==1&&capturer->callbacks==1);
    capture.OnStop(capturer);assert(audioStops==1);
  }
  {
    FlutterScreenCapture capture;auto previous=std::make_shared<RTCDesktopCapturer>();
    auto current=std::make_shared<RTCDesktopCapturer>();int audioStops=0;
    Audio(capture,current.get(),audioStops);
    capture.OnStop(previous);assert(audioStops==0&&capture.loopback_capturer_);
    previous->outcome=RTCDesktopCapturer::CS_FAILED;previous->observer=&capture;Result result;
    capture.FinishStart(previous,&result);
    assert(result.errors==1&&audioStops==0&&capture.loopback_owner_==current.get());
    capture.OnStop(current);assert(audioStops==1);
  }
  std::cout<<"Desktop capture startup: failed/stopped/success/foreign-session cleanup passed\n";
}
"""


def main():
    plugin = Path(__file__).resolve().parents[2]
    source = (plugin / "common/cpp/src/flutter_screen_capture.cc").read_text()
    startup = definition(source, "void FlutterScreenCapture::GetDisplayMedia(")
    startup = startup[startup.index("  // Do not publish a stream"):].rsplit("}", 1)[0]
    on_stop = definition(source, "void FlutterScreenCapture::OnStop(")
    harness = HARNESS.replace("// STARTUP", startup).replace("// ON_STOP", on_stop)
    with tempfile.TemporaryDirectory(prefix="bshare-desktop-capture-") as directory:
        work = Path(directory)
        (work / "test.cc").write_text(harness)
        binary = work / "test"
        subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                        str(work / "test.cc"), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
