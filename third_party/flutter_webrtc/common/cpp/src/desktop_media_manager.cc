#include "desktop_media_manager.h"
#include "desktop_media_writer.h"
#include "flutter_webrtc_base.h"
#include "rtc_audio_track.h"
#include "rtc_video_track.h"
#include "task_runner.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <filesystem>
#include <functional>
#include <mutex>
#include <thread>
#if defined(_WINDOWS)
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace flutter_webrtc_plugin {
namespace {
using bshare::media::AudioFrame;
using bshare::media::VideoFrame;
using Steady = std::chrono::steady_clock;
using VideoRef = scoped_refptr<RTCVideoFrame>;
using Result = std::shared_ptr<MethodResultProxy>;
int64_t NowUs() { return std::chrono::duration_cast<std::chrono::microseconds>(Steady::now().time_since_epoch()).count(); }

struct SavedMedia {
  std::string path;
  std::string error;
  int64_t frames = 0;
  int64_t duration_ms = 0;
  int64_t bytes = 0;
};
EncodableMap SavedMap(const SavedMedia& saved) {
  return {{EncodableValue("path"), EncodableValue(saved.path)},
    {EncodableValue("frames"), EncodableValue(saved.frames)},
    {EncodableValue("durationMs"), EncodableValue(saved.duration_ms)},
    {EncodableValue("bytes"), EncodableValue(saved.bytes)},
    {EncodableValue("audio"), EncodableValue(true)}};
}
std::filesystem::path Path(const std::string& value) { return std::filesystem::u8path(value); }
bool ValidDestination(const std::string& value, const char* extension, std::string& error) {
  const auto path = Path(value);
  std::error_code ec;
  if (value.empty() || value.find('\0') != std::string::npos || !path.is_absolute() || path.extension() != extension ||
      !std::filesystem::is_directory(path.parent_path(), ec) || ec ||
      std::filesystem::exists(path, ec) || ec) {
    error = "Choose a writable destination without an existing file"; return false;
  }
  return true;
}
void RemoveTemporary(const std::string& path) {
  std::error_code ignored; std::filesystem::remove(Path(path), ignored);
}
bool Publish(const std::string& temporary, const std::string& final_path, std::string& error) {
  const auto source = Path(temporary), target = Path(final_path);
#if defined(_WINDOWS)
  const bool moved = MoveFileExW(source.c_str(), target.c_str(), MOVEFILE_WRITE_THROUGH) != FALSE;
#else
  const bool moved = syscall(SYS_renameat2, AT_FDCWD, source.c_str(), AT_FDCWD, target.c_str(), 1 /* RENAME_NOREPLACE */) == 0;
#endif
  if (!moved) error = "Could not publish the completed media file";
  return moved;
}
bool Convert(VideoRef native, int canvas_width, int canvas_height, VideoFrame& output) {
  if (!native || native->width() < 1 || native->height() < 1 || native->width() > 8192 || native->height() > 8192) return false;
  const bool rotated = native->rotation() == RTCVideoFrame::kVideoRotation_90 || native->rotation() == RTCVideoFrame::kVideoRotation_270;
  const int width = rotated ? native->height() : native->width();
  const int height = rotated ? native->width() : native->height();
  if (canvas_width <= 0) canvas_width = width;
  if (canvas_height <= 0) canvas_height = height;
  const double scale = std::min(static_cast<double>(canvas_width) / width, static_cast<double>(canvas_height) / height);
  const int fit_width = std::max(1, std::min(canvas_width, static_cast<int>(std::round(width * scale))));
  const int fit_height = std::max(1, std::min(canvas_height, static_cast<int>(std::round(height * scale))));
  std::vector<uint8_t> scaled(static_cast<size_t>(fit_width) * fit_height * 4);
  if (native->ConvertToARGB(RTCVideoFrame::Type::kARGB, scaled.data(), 0, fit_width, fit_height) < 0) return false;
  output.width = canvas_width; output.height = canvas_height; output.stride = canvas_width * 4;
  output.bgra.assign(static_cast<size_t>(output.stride) * canvas_height, 0);
  const int left = (canvas_width - fit_width) / 2, top = (canvas_height - fit_height) / 2;
  for (int row = 0; row < fit_height; ++row) {
    std::memcpy(output.bgra.data() + static_cast<size_t>(row + top) * output.stride + left * 4,
      scaled.data() + static_cast<size_t>(row) * fit_width * 4, static_cast<size_t>(fit_width) * 4);
  }
  return true;
}

class Snapshot final : public RTCVideoRenderer<VideoRef> {
 public:
  VideoRef Capture(scoped_refptr<RTCVideoTrack> track) {
    track->AddRenderer(this);
    {
      std::unique_lock<std::mutex> lock(mutex_);
      changed_.wait_for(lock, std::chrono::seconds(3), [&] { return frame_ != nullptr; });
    }
    track->RemoveRenderer(this);
    std::lock_guard<std::mutex> lock(mutex_);
    return frame_;
  }
  void OnFrame(VideoRef frame) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!frame_) { frame_ = frame; changed_.notify_one(); }
  }
 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  VideoRef frame_;
};

struct AudioChunk {
  int rate = 48000;
  int channels = 2;
  int64_t time_us = 0;
  std::vector<int16_t> pcm;
};
struct NormalizedAudio {
  int64_t first_sample = 0;
  std::vector<int16_t> pcm;
  int64_t end() const { return first_sample + static_cast<int64_t>(pcm.size() / 2); }
};

class Recording final : public RTCVideoRenderer<VideoRef>, public AudioTrackSink,
                        public std::enable_shared_from_this<Recording> {
 public:
  using Started = std::function<void(const std::string&)>;
  using Finished = std::function<void(const SavedMedia&)>;
  Recording(scoped_refptr<RTCVideoTrack> video, scoped_refptr<RTCAudioTrack> audio,
             std::string path, std::string temporary, int fps)
      : video_(video), audio_(audio), path_(std::move(path)), temporary_(std::move(temporary)), fps_(fps) {}
  ~Recording() override {
    Stop({});
    if (worker_.joinable()) {
      if (worker_.get_id() == std::this_thread::get_id()) worker_.detach(); else worker_.join();
    }
  }
  void Start(Started started) {
    video_->AddRenderer(this);
    if (audio_) audio_->AddSink(this);
    worker_ = std::thread([self = shared_from_this(), started = std::move(started)] { self->Run(started); });
  }
  void Stop(Finished finished) {
    bool detach = false;
    SavedMedia completed;
    bool already_finished = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!detached_) { detached_ = true; detach = true; }
      if (!stopping_) { stopping_ = true; stop_us_ = NowUs(); }
      already_finished = finished_;
      if (already_finished) completed = saved_;
      else if (finished) completions_.push_back(std::move(finished));
    }
    if (detach) {
      video_->RemoveRenderer(this);
      if (audio_) audio_->RemoveSink(this);
    }
    changed_.notify_one();
    if (already_finished && finished) finished(completed);
  }
  void Join() { if (worker_.joinable()) worker_.join(); }
  void OnFrame(VideoRef frame) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stopping_) { latest_ = frame; latest_us_ = NowUs(); changed_.notify_one(); }
  }
  void OnData(const void* data, int bits, int rate, size_t channels, size_t frames) override {
    if (!data || bits != 16 || rate < 8000 || rate > 192000 || channels < 1 || channels > 2 || frames < 1 || frames > 19200) return;
    AudioChunk chunk;
    chunk.rate = rate; chunk.channels = static_cast<int>(channels);
    chunk.time_us = NowUs() - static_cast<int64_t>(frames) * 1000000 / rate;
    const auto* pcm = static_cast<const int16_t*>(data);
    chunk.pcm.assign(pcm, pcm + frames * channels);
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
    if (audio_queue_.size() >= 64) audio_queue_.pop_front();
    audio_queue_.push_back(std::move(chunk));
  }
 private:
  void Normalize(std::deque<AudioChunk>& chunks, std::deque<NormalizedAudio>& pending, int64_t origin, int64_t& expected) {
    for (const auto& chunk : chunks) {
      const int64_t source_frames = static_cast<int64_t>(chunk.pcm.size()) / chunk.channels;
      const int64_t frames = std::max<int64_t>(1, source_frames * 48000 / chunk.rate);
      NormalizedAudio output;
      output.first_sample = (chunk.time_us - origin) * 48000 / 1000000;
      if (expected >= 0 && std::abs(output.first_sample - expected) < 4800) output.first_sample = expected;
      output.pcm.resize(static_cast<size_t>(frames) * 2);
      for (int64_t i = 0; i < frames; ++i) {
        const int64_t source = std::min(source_frames - 1, i * chunk.rate / 48000);
        output.pcm[static_cast<size_t>(i) * 2] = chunk.pcm[static_cast<size_t>(source) * chunk.channels];
        output.pcm[static_cast<size_t>(i) * 2 + 1] = chunk.pcm[static_cast<size_t>(source) * chunk.channels + (chunk.channels == 2 ? 1 : 0)];
      }
      expected = output.end();
      pending.push_back(std::move(output));
    }
  }
  bool AudioUntil(bshare::media::IRawMediaWriter& writer, int64_t target_us,
                   std::deque<NormalizedAudio>& pending, int64_t& next_sample, std::string& error) {
    const int64_t target_sample = target_us * 48000 / 1000000;
    while (next_sample + 480 <= target_sample) {
      AudioFrame block;
      block.pts_us = next_sample * 1000000 / 48000;
      block.samples_s16.assign(960, 0);
      while (!pending.empty() && pending.front().end() <= next_sample) pending.pop_front();
      for (const auto& chunk : pending) {
        const int64_t first = std::max(next_sample, chunk.first_sample);
        const int64_t last = std::min(next_sample + 480, chunk.end());
        if (first < last) {
          std::copy(chunk.pcm.begin() + (first - chunk.first_sample) * 2,
            chunk.pcm.begin() + (last - chunk.first_sample) * 2,
            block.samples_s16.begin() + (first - next_sample) * 2);
        }
      }
      if (!writer.WriteAudio(block, error)) return false;
      next_sample += 480;
    }
    return true;
  }
  void Run(const Started& started) {
    SavedMedia saved;
    VideoRef first;
    int64_t origin = 0;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      changed_.wait_for(lock, std::chrono::seconds(3), [&] { return latest_ != nullptr || stopping_; });
      if (!stopping_) { first = latest_; origin = latest_us_; latest_ = nullptr; }
    }
    auto writer = bshare::media::CreatePlatformMediaWriter();
    VideoFrame frame;
    bool active = first && Convert(first, 0, 0, frame);
    const int width = frame.width & ~1, height = frame.height & ~1;
    if (!active || width < 2 || height < 2 || width > 4096 || height > 4096) {
      saved.error = "No supported video frame arrived for recording";
    } else if (!writer || !writer->Start(temporary_, width, height, fps_, saved.error)) {
      if (saved.error.empty()) saved.error = "Recording encoder is unavailable";
    } else {
      active = Convert(first, width, height, frame) && writer->WriteVideo(frame, saved.error);
      if (active) saved.frames = 1;
    }
    if (!active && saved.error.empty()) saved.error = "Could not initialize camera recording";
    if (!saved.error.empty()) active = false;
    started(active ? std::string{} : saved.error);
    int64_t last_video_us = 0, next_audio_sample = 0, expected_audio = -1;
    std::deque<NormalizedAudio> audio;
    while (active) {
      VideoRef latest;
      int64_t time_us = 0, target_us = 0;
      bool stop = false;
      std::deque<AudioChunk> chunks;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        changed_.wait_for(lock, std::chrono::milliseconds(10), [&] { return stopping_ || latest_ != nullptr; });
        stop = stopping_; target_us = (stop ? stop_us_ : NowUs()) - origin;
        latest = latest_; time_us = latest_us_ - origin; latest_ = nullptr;
        chunks.swap(audio_queue_);
      }
      Normalize(chunks, audio, origin, expected_audio);
      if (latest && time_us + 1000 >= last_video_us + 1000000 / fps_) {
        if (!Convert(latest, width, height, frame)) { saved.error = "Could not convert a recording frame"; break; }
        frame.pts_us = time_us;
        if (!writer->WriteVideo(frame, saved.error)) break;
        last_video_us = time_us; saved.frames++;
      }
      if (!AudioUntil(*writer, std::max<int64_t>(target_us, stop ? 40000 : 0), audio, next_audio_sample, saved.error)) break;
      saved.duration_ms = std::max<int64_t>(0, target_us / 1000);
      if (stop) break;
    }
    if (writer && active) {
      std::string finish_error;
      if (!writer->Finish(finish_error) && saved.error.empty()) saved.error = finish_error;
    }
    writer.reset();
    if (active && saved.frames > 0 && saved.error.empty() && Publish(temporary_, path_, saved.error)) {
      saved.path = path_;
      std::error_code ec;
      saved.bytes = static_cast<int64_t>(std::filesystem::file_size(Path(path_), ec));
      if (ec) saved.bytes = 0;
    } else RemoveTemporary(temporary_);
    Stop({});
    std::vector<Finished> completions;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      saved_ = saved; finished_ = true; completions.swap(completions_);
    }
    for (const auto& completion : completions) completion(saved);
  }
  scoped_refptr<RTCVideoTrack> video_;
  scoped_refptr<RTCAudioTrack> audio_;
  std::string path_, temporary_;
  int fps_;
  std::mutex mutex_;
  std::condition_variable changed_;
  VideoRef latest_;
  int64_t latest_us_ = 0, stop_us_ = 0;
  bool stopping_ = false, detached_ = false, finished_ = false;
  std::deque<AudioChunk> audio_queue_;
  std::vector<Finished> completions_;
  SavedMedia saved_;
  std::thread worker_;
};
}  // namespace

struct DesktopMediaManager::Impl {
  Impl(FlutterWebRTCBase* owner, TaskRunner* runner) : base(owner), task_runner(runner) {}
  ~Impl() {
    alive->store(false);
    for (auto& item : recordings) item.second->Stop({});
    for (auto& item : recordings) item.second->Join();
    recordings.clear();
    if (photo_worker.joinable()) photo_worker.join();
  }
  scoped_refptr<RTCMediaTrack> Track(const std::string& peer_id, const std::string& id, const char* kind) {
    auto* peer = base->PeerConnectionForId(peer_id);
    if (!peer || id.empty()) return nullptr;
    for (const auto& receiver : peer->receivers().std_vector()) {
      auto track = receiver->track();
      if (track && track->id().std_string() == id && track->kind().std_string() == kind) return track;
    }
    return nullptr;
  }
  void Post(std::function<void()> callback) {
    auto guard = alive;
    task_runner->EnqueueTask([guard, callback = std::move(callback)] { if (guard->load()) callback(); });
  }
  FlutterWebRTCBase* base;
  TaskRunner* task_runner;
  std::shared_ptr<std::atomic<bool>> alive = std::make_shared<std::atomic<bool>>(true);
  std::map<std::string, std::shared_ptr<Recording>> recordings;
  std::map<std::string, SavedMedia> completed;
  std::thread photo_worker;
  std::atomic<bool> photo_busy{false};
};

DesktopMediaManager::DesktopMediaManager(FlutterWebRTCBase* base, TaskRunner* runner) : impl_(std::make_unique<Impl>(base, runner)) {}
DesktopMediaManager::~DesktopMediaManager() = default;
void DesktopMediaManager::GetDirectories(std::unique_ptr<MethodResultProxy> result) {
  const auto directories = bshare::media::PlatformMediaDirectories();
  result->Success(EncodableValue(EncodableMap{
    {EncodableValue("supported"), EncodableValue(!directories.first.empty() && !directories.second.empty())},
    {EncodableValue("pictures"), EncodableValue(directories.first)},
    {EncodableValue("videos"), EncodableValue(directories.second)}}));
}
void DesktopMediaManager::TakePhoto(const EncodableMap& arguments, std::unique_ptr<MethodResultProxy> result) {
  const auto path = findString(arguments, "path");
  std::string error;
  auto track = impl_->Track(findString(arguments, "peerConnectionId"), findString(arguments, "videoTrackId"), "video");
  if (!track || !ValidDestination(path, ".jpg", error) || impl_->photo_busy.exchange(true)) {
    result->Error("desktop-media-failed", error.empty() ? "Camera photo is unavailable or busy" : error); return;
  }
  if (impl_->photo_worker.joinable()) impl_->photo_worker.join();
  const auto temporary = path + "." + impl_->base->GenerateUUID() + ".part.jpg";
  Result response(result.release());
  auto* implementation = impl_.get();
  scoped_refptr<RTCVideoTrack> video(static_cast<RTCVideoTrack*>(track.get()));
  impl_->photo_worker = std::thread([implementation, video, response, path, temporary] {
    Snapshot snapshot;
    auto native = snapshot.Capture(video);
    VideoFrame pixels;
    std::string error;
    if (!native || !Convert(native, 0, 0, pixels)) error = "No camera frame arrived for the photo";
    else if (bshare::media::WritePlatformPhotoJpeg(temporary, pixels, .92, error)) Publish(temporary, path, error);
    if (!error.empty()) RemoveTemporary(temporary);
    implementation->photo_busy.store(false);
    implementation->Post([response, path, error] {
      if (error.empty()) response->Success(EncodableValue(EncodableMap{{EncodableValue("path"), EncodableValue(path)}}));
      else response->Error("desktop-media-failed", error);
    });
  });
}
void DesktopMediaManager::StartRecording(const EncodableMap& arguments, std::unique_ptr<MethodResultProxy> result) {
  const auto path = findString(arguments, "path");
  const auto peer = findString(arguments, "peerConnectionId");
  std::string error;
  auto video = impl_->Track(peer, findString(arguments, "videoTrackId"), "video");
  const auto audio_id = findString(arguments, "audioTrackId");
  auto audio = impl_->Track(peer, audio_id, "audio");
  if (!video || (!audio_id.empty() && !audio) || !ValidDestination(path, ".mp4", error) || !impl_->recordings.empty()) {
    result->Error("desktop-media-failed", error.empty() ? "Camera recording is unavailable or busy" : error); return;
  }
  const int fps = arguments.find(EncodableValue("fps")) == arguments.end()
      ? 30 : findInt(arguments, "fps");
  if (fps < 1 || fps > 60) { result->Error("desktop-media-failed", "Unsupported recording frame rate"); return; }
  const auto id = impl_->base->GenerateUUID();
  auto recording = std::make_shared<Recording>(scoped_refptr<RTCVideoTrack>(static_cast<RTCVideoTrack*>(video.get())),
    audio ? scoped_refptr<RTCAudioTrack>(static_cast<RTCAudioTrack*>(audio.get())) : nullptr,
    path, path + "." + id + ".part.mp4", fps);
  impl_->recordings[id] = recording;
  Result response(result.release());
  auto* implementation = impl_.get();
  recording->Start([implementation, response, id](const std::string& error) {
    implementation->Post([implementation, response, id, error] {
      if (error.empty()) response->Success(EncodableValue(EncodableMap{{EncodableValue("recorderId"), EncodableValue(id)}}));
      else { implementation->recordings.erase(id); response->Error("desktop-media-failed", error); }
    });
  });
}
void DesktopMediaManager::StopRecording(const EncodableMap& arguments, std::unique_ptr<MethodResultProxy> result) {
  const auto id = findString(arguments, "recorderId");
  const auto completed = impl_->completed.find(id);
  if (completed != impl_->completed.end()) {
    if (completed->second.error.empty()) result->Success(EncodableValue(SavedMap(completed->second)));
    else result->Error("desktop-media-failed", completed->second.error);
    return;
  }
  const auto found = impl_->recordings.find(id);
  if (found == impl_->recordings.end()) { result->Error("desktop-media-failed", "Recording session is unavailable"); return; }
  Result response(result.release());
  auto* implementation = impl_.get();
  found->second->Stop([implementation, response, id](const SavedMedia& saved) {
    implementation->Post([implementation, response, id, saved] {
      if (implementation->completed.size() >= 8) implementation->completed.erase(implementation->completed.begin());
      implementation->completed[id] = saved;
      implementation->recordings.erase(id);
      if (saved.error.empty()) response->Success(EncodableValue(SavedMap(saved)));
      else response->Error("desktop-media-failed", saved.error);
    });
  });
}
}  // namespace flutter_webrtc_plugin
