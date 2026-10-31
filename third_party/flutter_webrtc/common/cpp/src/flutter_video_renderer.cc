#include "flutter_video_renderer.h"
#include <chrono>

namespace flutter_webrtc_plugin {

void FlutterVideoRenderer::SetFrameOutputEnabled(bool enabled) {
  bool notify = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_output_enabled_ = enabled;
    notify = enabled && frame_.get();
  }
  if (notify && registrar_) registrar_->MarkTextureFrameAvailable(texture_id_);
}

FlutterVideoRenderer::~FlutterVideoRenderer() {
  SetVideoTrack(nullptr);
  SetVirtualCameraOutput(false);
}

void FlutterVideoRenderer::SetVirtualCameraOutput(bool enabled) {
#if defined(_WINDOWS) || defined(BSHARE_LINUX_VIRTUAL_CAMERA)
  std::lock_guard<std::mutex> lock(mutex_);
  virtual_camera_enabled_ = enabled;
  virtual_camera_retry_at_ = 0;
  if (!enabled && virtual_camera_) {
    virtual_camera_->Clear();
    virtual_camera_.reset();
    virtual_camera_pixels_.clear();
  }
#endif
}

void FlutterVideoRenderer::initialize(
    TextureRegistrar* registrar,
    BinaryMessenger* messenger,
    TaskRunner* task_runner,
    std::unique_ptr<flutter::TextureVariant> texture,
    int64_t trxture_id) {
  registrar_ = registrar;
  texture_ = std::move(texture);
  texture_id_ = trxture_id;
  std::string channel_name =
      "FlutterWebRTC/Texture" + std::to_string(texture_id_);
  event_channel_ = EventChannelProxy::Create(messenger, task_runner, channel_name);
}

const FlutterDesktopPixelBuffer* FlutterVideoRenderer::CopyPixelBuffer(
    size_t width,
    size_t height) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!frame_output_enabled_) return nullptr;
  if (pixel_buffer_.get() && frame_.get()) {
    // ConvertToARGB already applies frame rotation. Its destination must have
    // the rotated dimensions, otherwise a quarter turn stretches the image.
    const bool quarter_turn = frame_->rotation() == RTCVideoFrame::kVideoRotation_90 ||
                              frame_->rotation() == RTCVideoFrame::kVideoRotation_270;
    const size_t output_width = quarter_turn ? frame_->height() : frame_->width();
    const size_t output_height = quarter_turn ? frame_->width() : frame_->height();
    if (pixel_buffer_->width != output_width ||
        pixel_buffer_->height != output_height) {
      size_t buffer_size = output_width * output_height * (32 >> 3);
      rgb_buffer_.reset(new uint8_t[buffer_size]);
      pixel_buffer_->width = output_width;
      pixel_buffer_->height = output_height;
      frame_dirty_ = true;
    }

    // Flutter may request this texture more than once between video frames.
    if (frame_dirty_) {
      frame_->ConvertToARGB(RTCVideoFrame::Type::kABGR, rgb_buffer_.get(), 0,
                            static_cast<int>(pixel_buffer_->width),
                            static_cast<int>(pixel_buffer_->height));
      frame_dirty_ = false;
    }

    pixel_buffer_->buffer = rgb_buffer_.get();
    return pixel_buffer_.get();
  }
  return nullptr;
}

void FlutterVideoRenderer::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  if (!frame || frame->width() <= 0 || frame->height() <= 0) {
    return;
  }
  std::unique_lock<std::mutex> lock(mutex_);
  const bool first_frame = !first_frame_rendered;
  if (first_frame) {
    EncodableMap params;
    params[EncodableValue("event")] = "didFirstFrameRendered";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    event_channel_->Success(EncodableValue(params));
    if (!pixel_buffer_) {
      pixel_buffer_.reset(new FlutterDesktopPixelBuffer());
    }
    first_frame_rendered = true;
  }
  if (first_frame || rotation_ != frame->rotation()) {
    EncodableMap params;
    params[EncodableValue("event")] = "didTextureChangeRotation";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    params[EncodableValue("rotation")] =
        EncodableValue((int32_t)frame->rotation());
    event_channel_->Success(EncodableValue(params));
    rotation_ = frame->rotation();
  }
  if (last_frame_size_.width != frame->width() ||
      last_frame_size_.height != frame->height()) {
    EncodableMap params;
    params[EncodableValue("event")] = "didTextureChangeVideoSize";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    params[EncodableValue("width")] = EncodableValue((int32_t)frame->width());
    params[EncodableValue("height")] = EncodableValue((int32_t)frame->height());
    event_channel_->Success(EncodableValue(params));

    last_frame_size_ = {(size_t)frame->width(), (size_t)frame->height()};
  }
  frame_ = frame;
  frame_dirty_ = true;
#if defined(_WINDOWS) || defined(BSHARE_LINUX_VIRTUAL_CAMERA)
  if (virtual_camera_enabled_) {
    const auto now = static_cast<uint64_t>(std::chrono::duration_cast<
        std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    if ((!virtual_camera_ || !virtual_camera_->IsReady()) &&
        now >= virtual_camera_retry_at_) {
      virtual_camera_.reset();
      virtual_camera_ =
          std::make_unique<bshare::virtual_camera::FramePublisher>();
      virtual_camera_retry_at_ = now + 1000;
    }
  }
  if (virtual_camera_enabled_ && virtual_camera_ && virtual_camera_->IsReady()) {
    const bool quarter_turn =
        frame->rotation() == RTCVideoFrame::kVideoRotation_90 ||
        frame->rotation() == RTCVideoFrame::kVideoRotation_270;
    const int output_width = quarter_turn ? frame->height() : frame->width();
    const int output_height = quarter_turn ? frame->width() : frame->height();
    if (output_width <= 4096 && output_height <= 4096 &&
        static_cast<uint64_t>(output_width) * output_height * 4 <= 33554432) {
      virtual_camera_pixels_.resize(
          static_cast<size_t>(output_width) * output_height * 4);
      // kARGB is BGRA in memory on supported little-endian desktop targets.
      // ConvertToARGB applies rotation;
      // publish independently of Flutter texture paints (including minimized UI).
      if (frame->ConvertToARGB(RTCVideoFrame::Type::kARGB,
                              virtual_camera_pixels_.data(), 0,
                              output_width, output_height) >= 0) {
        virtual_camera_->Publish(virtual_camera_pixels_.data(), output_width,
                                 output_height, output_width * 4);
      }
    } else {
      virtual_camera_->Clear();
    }
  }
#endif
  const bool notify_texture = frame_output_enabled_;
  lock.unlock();
  if (notify_texture) registrar_->MarkTextureFrameAvailable(texture_id_);
}

void FlutterVideoRenderer::SetVideoTrack(scoped_refptr<RTCVideoTrack> track) {
  if (track_ != track) {
    if (track_)
      track_->RemoveRenderer(this);
    track_ = track;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      last_frame_size_ = {0, 0};
      rotation_ = RTCVideoFrame::kVideoRotation_0;
      first_frame_rendered = false;
      frame_ = nullptr;
      frame_dirty_ = false;
#if defined(_WINDOWS) || defined(BSHARE_LINUX_VIRTUAL_CAMERA)
      if (virtual_camera_) {
        virtual_camera_->Clear();
        virtual_camera_.reset();
        virtual_camera_pixels_.clear();
      }
      virtual_camera_retry_at_ = 0;
#endif
    }
    if (track_)
      track_->AddRenderer(this);
  }
}

bool FlutterVideoRenderer::CheckMediaStream(std::string mediaId) {
  if (0 == mediaId.size() || 0 == media_stream_id.size()) {
    return false;
  }
  return mediaId == media_stream_id;
}

bool FlutterVideoRenderer::CheckVideoTrack(std::string mediaId) {
  if (0 == mediaId.size() || !track_) {
    return false;
  }
  return mediaId == track_->id().std_string();
}

FlutterVideoRendererManager::FlutterVideoRendererManager(
    FlutterWebRTCBase* base)
    : base_(base) {}

void FlutterVideoRendererManager::VideoRendererSetFrameOutputEnabled(
    int64_t texture_id, bool enabled,
    std::unique_ptr<MethodResultProxy> result) {
  auto it = renderers_.find(texture_id);
  if (it == renderers_.end()) {
    result->Error("VideoRendererNotFound", "Video texture is not available");
    return;
  }
  it->second->SetFrameOutputEnabled(enabled);
  result->Success();
}

void FlutterVideoRendererManager::VideoRendererSetVirtualCamera(
    int64_t texture_id, bool enabled,
    std::unique_ptr<MethodResultProxy> result) {
#if defined(_WINDOWS) || defined(BSHARE_LINUX_VIRTUAL_CAMERA)
  auto it = renderers_.find(texture_id);
  if (it == renderers_.end()) {
    result->Error("VideoRendererNotFound", "Video texture is not available");
    return;
  }
  it->second->SetVirtualCameraOutput(enabled);
  result->Success();
#else
  result->Error("UnsupportedPlatform", "Virtual camera is not supported on this platform");
#endif
}

void FlutterVideoRendererManager::CreateVideoRendererTexture(
    std::unique_ptr<MethodResultProxy> result) {
  auto texture = new RefCountedObject<FlutterVideoRenderer>();
  auto textureVariant =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
          [texture](size_t width,
                    size_t height) -> const FlutterDesktopPixelBuffer* {
            return texture->CopyPixelBuffer(width, height);
          }));

  auto texture_id = base_->textures_->RegisterTexture(textureVariant.get());
  texture->initialize(base_->textures_, base_->messenger_, base_->task_runner_,
                      std::move(textureVariant), texture_id);
  renderers_[texture_id] = texture;
  EncodableMap params;
  params[EncodableValue("textureId")] = EncodableValue(texture_id);
  result->Success(EncodableValue(params));
}

void FlutterVideoRendererManager::VideoRendererSetSrcObject(
    int64_t texture_id,
    const std::string& stream_id,
    const std::string& owner_tag,
    const std::string& track_id) {
  scoped_refptr<RTCMediaStream> stream =
      base_->MediaStreamForId(stream_id, owner_tag);

  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    FlutterVideoRenderer* renderer = it->second.get();
    if (stream.get()) {
      auto video_tracks = stream->video_tracks();
      if (video_tracks.size() > 0) {
        if (track_id == std::string()) {
          renderer->SetVideoTrack(video_tracks[0]);
        } else {
          for (auto track : video_tracks.std_vector()) {
            if (track->id().std_string() == track_id) {
              renderer->SetVideoTrack(track);
              break;
            }
          }
        }
        renderer->media_stream_id = stream_id;
      }
    } else {
      renderer->SetVideoTrack(nullptr);
    }
  }
}

void FlutterVideoRendererManager::VideoRendererDispose(
    int64_t texture_id,
    std::unique_ptr<MethodResultProxy> result) {
  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    it->second->SetVideoTrack(nullptr);
#if defined(_WINDOWS)
    base_->textures_->UnregisterTexture(texture_id,
                                        [&, it] { renderers_.erase(it); });
#else
    base_->textures_->UnregisterTexture(texture_id);
    renderers_.erase(it);
#endif
    result->Success();
    return;
  }
  result->Error("VideoRendererDisposeFailed",
                "VideoRendererDispose() texture not found!");
}

}  // namespace flutter_webrtc_plugin
