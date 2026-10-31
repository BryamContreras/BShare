"""Run the production recording/snapshot worker with synthetic SDK tracks.

No Flutter engine or actual peer is started. Uses the bundled video-frame type
and actual Windows writer; owned temporary JPEG/MP4 files are removed afterward.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / 'third_party/flutter_webrtc'
FIXTURE = r'''
#include <cassert>
#include <fstream>
#include <future>
#include <iostream>
using namespace flutter_webrtc_plugin;
using namespace libwebrtc;
class Video : public RTCVideoTrack {
 public:
  mutable std::mutex lock;
  std::vector<RTCVideoRenderer<VideoRef>*> sinks;
  RTCTrackState state() const override { return kLive; }
  const libwebrtc::string kind() const override { return "video"; }
  const libwebrtc::string id() const override { return "synthetic-video"; }
  bool enabled() const override { return true; }
  bool set_enabled(bool) override { return true; }
  void AddRenderer(RTCVideoRenderer<VideoRef>* sink) override { std::lock_guard<std::mutex> guard(lock); sinks.push_back(sink); }
  void RemoveRenderer(RTCVideoRenderer<VideoRef>* sink) override {
    std::lock_guard<std::mutex> guard(lock); sinks.erase(std::remove(sinks.begin(), sinks.end(), sink), sinks.end());
  }
  void Emit(VideoRef frame) { std::lock_guard<std::mutex> guard(lock); for (auto* sink : sinks) sink->OnFrame(frame); }
  size_t Count() { std::lock_guard<std::mutex> guard(lock); return sinks.size(); }
};
class Audio : public RTCAudioTrack {
 public:
  std::mutex lock;
  std::vector<AudioTrackSink*> sinks;
  RTCTrackState state() const override { return kLive; }
  const libwebrtc::string kind() const override { return "audio"; }
  const libwebrtc::string id() const override { return "synthetic-audio"; }
  bool enabled() const override { return true; }
  bool set_enabled(bool) override { return true; }
  void SetVolume(double) override { assert(false); }
  void AddSink(AudioTrackSink* sink) override { std::lock_guard<std::mutex> guard(lock); sinks.push_back(sink); }
  void RemoveSink(AudioTrackSink* sink) override { std::lock_guard<std::mutex> guard(lock); sinks.erase(std::remove(sinks.begin(), sinks.end(), sink), sinks.end()); }
  void Emit() { int16_t samples[480]{}; for (int i = 0; i < 480; ++i) samples[i] = i % 48 < 24 ? 5000 : -5000;
    std::lock_guard<std::mutex> guard(lock); for (auto* sink : sinks) sink->OnData(samples, 16, 48000, 1, 480);
  }
  size_t Count() { std::lock_guard<std::mutex> guard(lock); return sinks.size(); }
};
VideoRef Frame(int width, int height) {
  std::vector<uint8_t> y(static_cast<size_t>(width) * height, 200);
  std::vector<uint8_t> chroma(static_cast<size_t>(width / 2) * height / 2, 128);
  return RTCVideoFrame::Create(width, height, y.data(), width, chroma.data(), width / 2, chroma.data(), width / 2);
}
// The platform boundary is tested with its real EncodableMap parser and real
// recording worker. Only the peer lookup and Flutter main-thread queue differ.
namespace flutter_webrtc_plugin {
scoped_refptr<RTCVideoTrack> contract_video;
scoped_refptr<RTCAudioTrack> contract_audio;
std::mutex contract_pending_mutex;
std::deque<std::function<void()>> contract_pending;
struct ContractBase {
  int serial = 0;
  std::string GenerateUUID() { return "synthetic-" + std::to_string(serial++); }
};
struct DesktopMediaManager::Impl {
  ContractBase owner;
  ContractBase* base = &owner;
  std::map<std::string, std::shared_ptr<Recording>> recordings;
  std::map<std::string, SavedMedia> completed;
  ~Impl() {
    for (auto& item : recordings) item.second->Stop({});
    for (auto& item : recordings) item.second->Join();
  }
  scoped_refptr<RTCMediaTrack> Track(const std::string& peer, const std::string& id, const char* kind) {
    if (peer != "synthetic-peer") return nullptr;
    if (std::string(kind) == "video" && id == "synthetic-video") return contract_video;
    if (std::string(kind) == "audio" && id == "synthetic-audio") return contract_audio;
    return nullptr;
  }
  void Post(std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(contract_pending_mutex); contract_pending.push_back(std::move(callback));
  }
};
DesktopMediaManager::DesktopMediaManager(FlutterWebRTCBase*, TaskRunner*) : impl_(std::make_unique<Impl>()) {}
DesktopMediaManager::~DesktopMediaManager() = default;
// ACTUAL_START_RECORDING
// ACTUAL_STOP_RECORDING
}
struct Outcome { bool success; EncodableMap value; std::string error; };
class ContractResult : public MethodResultProxy {
 public:
  explicit ContractResult(std::shared_ptr<std::promise<Outcome>> promise) : promise_(std::move(promise)) {}
  void Success() override { promise_->set_value({true, {}, {}}); }
  void Success(const EncodableValue& value) override { promise_->set_value({true, std::get<EncodableMap>(value), {}}); }
  void Error(const std::string& code, const std::string& error, const EncodableValue&) override { Error(code, error); }
  void Error(const std::string&, const std::string& error) override { promise_->set_value({false, {}, error}); }
  void NotImplemented() override { assert(false); }
 private:
  std::shared_ptr<std::promise<Outcome>> promise_;
};
// Public methods have asynchronous platform replies; the real worker produces
// them, then this test pumps its queued callback on the caller's thread.
// PRIVATE_QUEUE_PUMP
int main(int argc, char** argv) {
  assert(argc == 2); const std::string directory = argv[1];
  scoped_refptr<Video> video = new RefCountedObject<Video>();
  scoped_refptr<Audio> audio = new RefCountedObject<Audio>();
  const auto first = Frame(320, 240), adapted = Frame(640, 360);
  {
    Snapshot capture;
    auto captured = std::async(std::launch::async, [&] { return capture.Capture(video); });
    while (!video->Count()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    video->Emit(first);
    assert(captured.wait_for(std::chrono::seconds(1)) == std::future_status::ready);
    assert(captured.get()); assert(video->Count() == 0);
  }
  {
    const std::string path = directory + "/recorded.mp4", temporary = directory + "/owned.part.mp4";
    auto recording = std::make_shared<Recording>(video, audio, path, temporary, 30);
    std::promise<std::string> started;
    recording->Start([&](const std::string& error) { started.set_value(error); });
    video->Emit(first);
    auto ready = started.get_future(); assert(ready.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    const auto error = ready.get(); if (!error.empty()) { std::cerr << error << "\n"; return 1; }
    assert(!std::filesystem::exists(Path(path)) && std::filesystem::exists(Path(temporary)));
    for (int index = 0; index < 60; ++index) {
      if ((index & 1) == 0) video->Emit(index < 30 ? first : adapted);
      audio->Emit(); std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    std::promise<SavedMedia> finished; auto complete = finished.get_future();
    recording->Stop([&](const SavedMedia& saved) { finished.set_value(saved); });
    assert(complete.wait_for(std::chrono::seconds(10)) == std::future_status::ready);
    const auto saved = complete.get(); recording->Join();
    if (!saved.error.empty()) { std::cerr << saved.error << "\n"; return 1; }
    assert(saved.path == path && saved.frames >= 10 && saved.duration_ms >= 500 && saved.bytes > 1000);
    assert(std::filesystem::exists(Path(path)) && !std::filesystem::exists(Path(temporary)));
    bool duplicate = false; recording->Stop([&](const SavedMedia& value) { duplicate = value.path == path && value.frames == saved.frames; });
    assert(duplicate && video->Count() == 0 && audio->Count() == 0);
  }
  {
    const std::string path = directory + "/silent.mp4", temporary = directory + "/silent.part.mp4";
    auto recording = std::make_shared<Recording>(video, nullptr, path, temporary, 30);
    std::promise<std::string> started; auto initial = started.get_future();
    recording->Start([&](const std::string& error) { started.set_value(error); });
    video->Emit(first);
    assert(initial.wait_for(std::chrono::seconds(5)) == std::future_status::ready && initial.get().empty());
    std::this_thread::sleep_for(std::chrono::milliseconds(120)); video->Emit(first);
    std::promise<SavedMedia> finished; auto complete = finished.get_future();
    recording->Stop([&](const SavedMedia& saved) { finished.set_value(saved); });
    assert(complete.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    const auto saved = complete.get(); recording->Join();
    assert(saved.error.empty() && saved.bytes > 1000 && saved.path == path);
    assert(audio->Count() == 0 && video->Count() == 0);
  }
  {
    const std::string path = directory + "/cancelled.mp4", temporary = directory + "/cancelled.part.mp4";
    auto recording = std::make_shared<Recording>(video, nullptr, path, temporary, 30);
    std::promise<std::string> started; auto initial = started.get_future();
    recording->Start([&](const std::string& error) { started.set_value(error); });
    std::promise<SavedMedia> finished; auto complete = finished.get_future();
    recording->Stop([&](const SavedMedia& saved) { finished.set_value(saved); });
    assert(initial.wait_for(std::chrono::seconds(2)) == std::future_status::ready && !initial.get().empty());
    assert(complete.wait_for(std::chrono::seconds(2)) == std::future_status::ready && !complete.get().error.empty());
    recording->Join(); assert(!std::filesystem::exists(Path(path)) && !std::filesystem::exists(Path(temporary)));
  }
  {
    const std::string existing = directory + "/existing.jpg", temporary = directory + "/publish.part.jpg";
    { std::ofstream file(Path(existing)); file << "keep-original"; }
    { std::ofstream file(Path(temporary)); file << "replacement"; }
    std::string error; assert(!Publish(temporary, existing, error));
    std::ifstream file(Path(existing)); std::string original; file >> original; assert(original == "keep-original");
    RemoveTemporary(temporary);
  }
  {
    contract_video = video; contract_audio = audio;
    ContractManager manager;
    for (bool with_audio : {false, true}) {
      const auto path = directory + (with_audio ? "/api-audio.mp4" : "/api-no-fps.mp4");
      EncodableMap arguments{{EncodableValue("path"), EncodableValue(path)},
        {EncodableValue("peerConnectionId"), EncodableValue("synthetic-peer")},
        {EncodableValue("videoTrackId"), EncodableValue("synthetic-video")}};
      if (with_audio) arguments[EncodableValue("audioTrackId")] = EncodableValue("synthetic-audio");
      // Deliberately omit fps, as the real Dart camera-media service does.
      auto start = std::make_shared<std::promise<Outcome>>(); auto started = start->get_future();
      manager.StartRecording(arguments, std::make_unique<ContractResult>(start));
      video->Emit(first);
      const auto ready = manager.Wait(started);
      if (!ready.success) { std::cerr << ready.error << "\n"; return 1; }
      const auto id = findString(ready.value, "recorderId"); assert(!id.empty());
      std::this_thread::sleep_for(std::chrono::milliseconds(120));
      video->Emit(first); if (with_audio) audio->Emit();
      auto stop = std::make_shared<std::promise<Outcome>>(); auto stopped = stop->get_future();
      manager.StopRecording({{EncodableValue("recorderId"), EncodableValue(id)}}, std::make_unique<ContractResult>(stop));
      const auto saved = manager.Wait(stopped);
      if (!saved.success) { std::cerr << saved.error << "\n"; return 1; }
      assert(findString(saved.value, "path") == path && std::filesystem::file_size(Path(path)) > 1000);
      assert(video->Count() == 0 && audio->Count() == 0);
    }
    for (const auto& fps : {EncodableValue(-1), EncodableValue(0), EncodableValue(61), EncodableValue(30.0), EncodableValue("30")}) {
      EncodableMap arguments{{EncodableValue("path"), EncodableValue(directory + "/invalid-fps.mp4")},
        {EncodableValue("peerConnectionId"), EncodableValue("synthetic-peer")},
        {EncodableValue("videoTrackId"), EncodableValue("synthetic-video")}, {EncodableValue("fps"), fps}};
      auto result = std::make_shared<std::promise<Outcome>>(); auto ready = result->get_future();
      manager.StartRecording(arguments, std::make_unique<ContractResult>(result));
      const auto rejected = manager.Wait(ready);
      assert(!rejected.success && rejected.error == "Unsupported recording frame rate");
      assert(video->Count() == 0 && audio->Count() == 0);
      assert(!std::filesystem::exists(Path(directory + "/invalid-fps.mp4")));
    }
    contract_video = nullptr; contract_audio = nullptr;
  }
  std::cout << "Actual worker: snapshot without texture, remote PCM, silent AAC without any audio sink, stable canvas across adaptation, atomic publication, idempotent stop and cancel without frames.\n";
  std::cout << "Actual platform API: missing fps defaults to 30 with/without remote audio; invalid explicit fps rejected before attaching tracks.\n";
}
'''

def production_method(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start)
    depth, end = 1, cursor + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def controller_source():
    production = (PLUGIN / 'common/cpp/src/desktop_media_manager.cc').read_text()
    fixture_source = FIXTURE
    for marker, signature in [
        ('// ACTUAL_START_RECORDING', 'void DesktopMediaManager::StartRecording('),
        ('// ACTUAL_STOP_RECORDING', 'void DesktopMediaManager::StopRecording('),
    ]:
        fixture_source = fixture_source.replace(marker, production_method(production, signature))
    # The queue pump does not alter the extracted API method.
    fixture_source = fixture_source.replace('// PRIVATE_QUEUE_PUMP', r'''
class ContractManager : public DesktopMediaManager {
 public:
  ContractManager() : DesktopMediaManager(nullptr, nullptr) {}
  Outcome Wait(std::future<Outcome>& future) {
    const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (future.wait_for(std::chrono::milliseconds(0)) != std::future_status::ready) {
      std::function<void()> callback;
      { std::lock_guard<std::mutex> lock(contract_pending_mutex);
        if (!contract_pending.empty()) { callback = std::move(contract_pending.front()); contract_pending.pop_front(); } }
      if (callback) callback();
      assert(std::chrono::steady_clock::now() < until);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return future.get();
  }
};
''')
    return production[:production.index('\nstruct DesktopMediaManager::Impl')] + '\n}\n' + fixture_source


@unittest.skipUnless(os.name == 'nt', 'Actual Windows writer contract')
class DesktopCameraMediaControllerTest(unittest.TestCase):
    def test_production_workers_and_owned_files(self):
        source = controller_source()
        flutter = Path(shutil.which('flutter')).resolve().parents[1]
        sdk = PLUGIN / 'third_party/libwebrtc'
        with tempfile.TemporaryDirectory(prefix='bshare-owned-worker-') as temp:
            directory = Path(temp); fixture = directory / 'fixture.cpp'; binary = directory / 'fixture.exe'
            fixture.write_text(source)
            arguments = ['/nologo', '/std:c++17', '/W4', '/WX', '/wd4100', '/EHsc', '/D_WINDOWS', '/DRTC_DESKTOP_DEVICE', '/DLIB_WEBRTC_API_DLL', '/DNOMINMAX',
                f'/I{PLUGIN / "common/cpp/include"}', f'/I{sdk / "include"}',
                f'/I{flutter / "bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper/include"}',
                f'/I{flutter / "bin/cache/artifacts/engine/windows-x64"}',
                str(fixture), str(PLUGIN / 'windows/desktop_media_writer_mf.cc'), f'/Fo{directory}/', f'/Fe{binary}',
                '/link', str(sdk / 'lib/libwebrtc.dll.lib'), 'mfplat.lib', 'mfreadwrite.lib', 'mfuuid.lib', 'windowscodecs.lib', 'ole32.lib', 'oleaut32.lib', 'shell32.lib', 'uuid.lib']
            compiler = shutil.which('cl')
            if compiler: command = [compiler, *arguments]
            else:
                vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
                installation = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], capture_output=True, text=True, timeout=20, check=True).stdout.strip()
                script = directory / 'compile.cmd'
                script.write_text('@echo off\ncall "' + str(Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat') + '" >nul\nif errorlevel 1 exit /b %errorlevel%\ncl ' + ' '.join('"' + option + '"' for option in arguments) + '\nexit /b %errorlevel%\n')
                command = ['cmd', '/c', str(script)]
            built = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            environment = dict(os.environ, PATH=str(sdk / 'lib') + os.pathsep + os.environ['PATH'])
            executed = subprocess.run([str(binary), str(directory)], env=environment, cwd=directory, capture_output=True, text=True, timeout=30)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            print(executed.stdout.strip())

if __name__ == '__main__': unittest.main()
