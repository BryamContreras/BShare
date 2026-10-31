#include "desktop_media_writer.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gst/app/gstappsrc.h>
#include <gst/gst.h>

#include <algorithm>
#include <cstring>
#include <mutex>

namespace bshare::media {
namespace {
bool Initialize(std::string& error) {
  static std::once_flag once;
  static std::string failure;
  std::call_once(once, [] {
    GError* detail = nullptr;
    if (!gst_init_check(nullptr, nullptr, &detail)) {
      failure = detail ? detail->message : "GStreamer initialization failed";
    }
    if (detail) g_error_free(detail);
  });
  error = failure;
  return failure.empty();
}

bool Valid(const VideoFrame& frame) {
  return frame.width > 0 && frame.height > 0 && frame.width <= 4096 &&
         frame.height <= 4096 && frame.stride >= frame.width * 4 &&
         frame.bgra.size() >= static_cast<size_t>(frame.stride) * frame.height;
}

class GStreamerWriter final : public IRawMediaWriter {
 public:
  ~GStreamerWriter() override { Reset(); }

  bool Start(const std::string& path, int width, int height, int fps,
             std::string& error) override {
    if (pipeline_ || width < 2 || height < 2 || (width & 1) || (height & 1) ||
        width > 4096 || height > 4096 || fps < 1 || fps > 60 || !Initialize(error)) {
      if (error.empty()) error = "Invalid recording configuration";
      return false;
    }
    failure_.clear();
    last_video_pts_ = last_audio_pts_ = -1;
    for (const auto* name : {"openh264enc", "mp4mux"}) {
      auto* factory = gst_element_factory_find(name);
      if (!factory) {
        error = std::string("Missing GStreamer recording component: ") + name;
        return false;
      }
      gst_object_unref(factory);
    }
    // Distributions package different AAC implementations. These are fixed
    // factory names, not input supplied by Dart or an output filename.
    const char* audio_encoder = nullptr;
    for (const auto* name : {"voaacenc", "fdkaacenc", "avenc_aac"}) {
      auto* factory = gst_element_factory_find(name);
      if (!factory) continue;
      gst_object_unref(factory);
      audio_encoder = name;
      break;
    }
    if (!audio_encoder) {
      error = "Missing GStreamer AAC encoder: voaacenc, fdkaacenc or avenc_aac";
      return false;
    }
    // Paths are set as properties, never interpolated into a pipeline string.
    // Both appsrc queues are bounded. No camera/microphone source is opened.
    const std::string description = std::string(
        "appsrc name=video is-live=true format=time block=false "
        "! videoconvert ! video/x-raw,format=I420 "
        "! openh264enc bitrate=6000000 complexity=low "
        "! h264parse ! video/x-h264,stream-format=avc,alignment=au ! mux. "
        "appsrc name=audio is-live=true format=time block=false "
        "! audioconvert ! ") + audio_encoder +
        " bitrate=128000 ! aacparse ! mux. "
        "mp4mux name=mux faststart=true ! filesink name=output";
    GError* detail = nullptr;
    pipeline_ = gst_parse_launch(description.c_str(), &detail);
    if (detail || !pipeline_) {
      error = detail ? detail->message : "Recording pipeline creation failed";
      if (detail) g_error_free(detail);
      Reset();
      return false;
    }
    video_ = gst_bin_get_by_name(GST_BIN(pipeline_), "video");
    audio_ = gst_bin_get_by_name(GST_BIN(pipeline_), "audio");
    auto* output = gst_bin_get_by_name(GST_BIN(pipeline_), "output");
    g_object_set(output, "location", path.c_str(), nullptr);
    gst_object_unref(output);
    auto* caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING,
        "BGRA", "width", G_TYPE_INT, width, "height", G_TYPE_INT, height,
        "framerate", GST_TYPE_FRACTION, fps, 1, nullptr);
    gst_app_src_set_caps(GST_APP_SRC(video_), caps);
    gst_caps_unref(caps);
    caps = gst_caps_from_string("audio/x-raw,format=S16LE,layout=interleaved,"
                               "rate=48000,channels=2,channel-mask=(bitmask)0x3");
    gst_app_src_set_caps(GST_APP_SRC(audio_), caps);
    gst_caps_unref(caps);
    // Keep at most a small preview-independent backlog. Older video may be
    // dropped under encoder pressure; audio overflow stops with a clear error.
    g_object_set(video_, "max-bytes", std::min<guint64>(
                     static_cast<guint64>(width) * height * 4 * 12, 64 * 1024 * 1024),
                 "leaky-type", GST_APP_LEAKY_TYPE_DOWNSTREAM, nullptr);
    g_object_set(audio_, "max-bytes", static_cast<guint64>(48000 * 2 * 2), nullptr);
    width_ = width;
    height_ = height;
    fps_ = fps;
    if (gst_element_set_state(pipeline_, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
      error = "Recording pipeline could not start";
      Reset();
      return false;
    }
    // Waiting for preroll here would deadlock: the shared controller writes
    // the first video frame before supplying the matching audio samples.
    return CheckError(error);
  }

  bool WriteVideo(const VideoFrame& frame, std::string& error) override {
    if (!pipeline_ || !Valid(frame) || frame.width != width_ ||
        frame.height != height_ || frame.pts_us < 0 ||
        frame.pts_us <= last_video_pts_) {
      error = "Invalid recording video frame";
      return false;
    }
    if (!CheckError(error)) return false;
    const size_t row = static_cast<size_t>(width_) * 4;
    auto* buffer = gst_buffer_new_allocate(nullptr, row * height_, nullptr);
    if (!buffer) { error = "Video buffer allocation failed"; return false; }
    GstMapInfo mapped;
    if (!gst_buffer_map(buffer, &mapped, GST_MAP_WRITE)) {
      gst_buffer_unref(buffer);
      error = "Video buffer mapping failed";
      return false;
    }
    for (int y = 0; y < height_; ++y) {
      std::memcpy(mapped.data + y * row, frame.bgra.data() + y * frame.stride, row);
    }
    gst_buffer_unmap(buffer, &mapped);
    GST_BUFFER_PTS(buffer) = static_cast<GstClockTime>(frame.pts_us) * GST_USECOND;
    GST_BUFFER_DURATION(buffer) = GST_SECOND / fps_;
    if (gst_app_src_push_buffer(GST_APP_SRC(video_), buffer) != GST_FLOW_OK) {
      error = failure_ = "Recording video input closed";
      return false;
    }
    last_video_pts_ = frame.pts_us;
    return CheckError(error);
  }

  bool WriteAudio(const AudioFrame& frame, std::string& error) override {
    if (!pipeline_ || frame.sample_rate != 48000 || frame.channels != 2 ||
        frame.samples_s16.empty() || frame.samples_s16.size() % 2 ||
        frame.pts_us < 0 || frame.pts_us <= last_audio_pts_) {
      error = "Invalid recording audio frame";
      return false;
    }
    if (!CheckError(error)) return false;
    constexpr guint64 maximum_audio_bytes = 48000 * 2 * 2;
    const size_t bytes = frame.samples_s16.size() * sizeof(int16_t);
    const auto queued = gst_app_src_get_current_level_bytes(GST_APP_SRC(audio_));
    if (bytes > maximum_audio_bytes || queued > maximum_audio_bytes - bytes) {
      error = failure_ = "Recording encoder cannot keep up with received audio";
      return false;
    }
    auto* buffer = gst_buffer_new_allocate(nullptr, bytes, nullptr);
    if (!buffer) { error = "Audio buffer allocation failed"; return false; }
    gst_buffer_fill(buffer, 0, frame.samples_s16.data(), bytes);
    GST_BUFFER_PTS(buffer) = static_cast<GstClockTime>(frame.pts_us) * GST_USECOND;
    GST_BUFFER_DURATION(buffer) = gst_util_uint64_scale(
        frame.samples_s16.size() / frame.channels, GST_SECOND, frame.sample_rate);
    if (gst_app_src_push_buffer(GST_APP_SRC(audio_), buffer) != GST_FLOW_OK) {
      error = failure_ = "Recording audio input closed";
      return false;
    }
    last_audio_pts_ = frame.pts_us;
    return CheckError(error);
  }

  bool Finish(std::string& error) override {
    if (!pipeline_) { error = "Recording is not open"; return false; }
    bool success = CheckError(error);
    if (success) {
      if (gst_app_src_end_of_stream(GST_APP_SRC(video_)) != GST_FLOW_OK ||
          gst_app_src_end_of_stream(GST_APP_SRC(audio_)) != GST_FLOW_OK) {
        error = "Recording input closed before finalization";
        Reset();
        return false;
      }
      auto* bus = gst_element_get_bus(pipeline_);
      auto* message = gst_bus_timed_pop_filtered(bus, 15 * GST_SECOND,
          static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
      gst_object_unref(bus);
      if (!message) { error = "Recording finalization timed out"; success = false; }
      else {
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
          ReadError(message, error);
          success = false;
        }
        gst_message_unref(message);
      }
    }
    Reset();
    return success;
  }

 private:
  static void ReadError(GstMessage* message, std::string& error) {
    GError* detail = nullptr;
    gchar* debug = nullptr;
    gst_message_parse_error(message, &detail, &debug);
    error = detail ? detail->message : "Recording pipeline failed";
    if (detail) g_error_free(detail);
    g_free(debug);
  }
  bool CheckError(std::string& error) {
    if (!failure_.empty()) { error = failure_; return false; }
    auto* bus = gst_element_get_bus(pipeline_);
    auto* message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    gst_object_unref(bus);
    if (!message) return true;
    ReadError(message, error);
    failure_ = error;
    gst_message_unref(message);
    return false;
  }
  void Reset() {
    if (pipeline_) gst_element_set_state(pipeline_, GST_STATE_NULL);
    if (video_) gst_object_unref(video_);
    if (audio_) gst_object_unref(audio_);
    if (pipeline_) gst_object_unref(pipeline_);
    pipeline_ = video_ = audio_ = nullptr;
  }
  GstElement* pipeline_ = nullptr;
  GstElement* video_ = nullptr;
  GstElement* audio_ = nullptr;
  int width_ = 0, height_ = 0, fps_ = 30;
  int64_t last_video_pts_ = -1, last_audio_pts_ = -1;
  std::string failure_;
};
}  // namespace

std::unique_ptr<IRawMediaWriter> CreatePlatformMediaWriter() {
  return std::make_unique<GStreamerWriter>();
}

bool WritePlatformPhotoJpeg(const std::string& path, const VideoFrame& frame,
                            double quality, std::string& error) {
  if (!Valid(frame)) { error = "Invalid photo frame"; return false; }
  auto* pixels = gdk_pixbuf_new(GDK_COLORSPACE_RGB, false, 8, frame.width, frame.height);
  if (!pixels) { error = "Photo allocation failed"; return false; }
  const int stride = gdk_pixbuf_get_rowstride(pixels);
  auto* destination = gdk_pixbuf_get_pixels(pixels);
  for (int y = 0; y < frame.height; ++y) {
    const auto* source = frame.bgra.data() + y * frame.stride;
    auto* row = destination + y * stride;
    for (int x = 0; x < frame.width; ++x) {
      row[x * 3] = source[x * 4 + 2];
      row[x * 3 + 1] = source[x * 4 + 1];
      row[x * 3 + 2] = source[x * 4];
    }
  }
  const auto q = std::to_string(static_cast<int>(std::clamp(quality, .01, 1.) * 100));
  GError* detail = nullptr;
  const bool ok = gdk_pixbuf_save(pixels, path.c_str(), "jpeg", &detail,
                                "quality", q.c_str(), nullptr);
  if (!ok) error = detail ? detail->message : "Photo encoding failed";
  if (detail) g_error_free(detail);
  g_object_unref(pixels);
  return ok;
}

std::pair<std::string, std::string> PlatformMediaDirectories() {
  const auto directory = [](GUserDirectory kind, const char* fallback) {
    const auto* value = g_get_user_special_dir(kind);
    if (value && *value) return std::string(value);
    return std::string(g_get_home_dir()) + "/" + fallback;
  };
  return {directory(G_USER_DIRECTORY_PICTURES, "Pictures"),
          directory(G_USER_DIRECTORY_VIDEOS, "Videos")};
}
}  // namespace bshare::media
