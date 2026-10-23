#include "flutter_video_renderer.h"

#include <cassert>
#include <chrono>
#include <cstring>
#include <iostream>
#include <vector>

namespace {

std::vector<int32_t> emitted_rotations;

class TestEvents : public EventChannelProxy {
 public:
  void Success(const EncodableValue& event, bool) override {
    const auto& params = std::get<EncodableMap>(event);
    if (std::get<std::string>(params.at(EncodableValue("event"))) ==
        "didTextureChangeRotation") {
      emitted_rotations.push_back(
          std::get<int32_t>(params.at(EncodableValue("rotation"))));
    }
  }
};

class TestTextures : public TextureRegistrar {
 public:
  int frames_available = 0;
  int64_t RegisterTexture(flutter::TextureVariant*) override { return 7; }
  bool MarkTextureFrameAvailable(int64_t) override {
    ++frames_available;
    return true;
  }
  bool UnregisterTexture(int64_t) override { return true; }
};

class TestFrame : public libwebrtc::RTCVideoFrame {
 public:
  TestFrame(int width, int height, VideoRotation rotation)
      : width_(width), height_(height), rotation_(rotation) {}

  int conversions = 0;
  int converted_width = 0;
  int converted_height = 0;
  libwebrtc::scoped_refptr<RTCVideoFrame> Copy() override { return this; }
  int width() const override { return width_; }
  int height() const override { return height_; }
  VideoRotation rotation() override { return rotation_; }
  const uint8_t* DataY() const override { return nullptr; }
  const uint8_t* DataU() const override { return nullptr; }
  const uint8_t* DataV() const override { return nullptr; }
  int StrideY() const override { return width_; }
  int StrideU() const override { return (width_ + 1) / 2; }
  int StrideV() const override { return (width_ + 1) / 2; }
  int ConvertToARGB(Type type, uint8_t* output, int, int width,
                    int height) override {
    assert(type == Type::kABGR);
    ++conversions;
    converted_width = width;
    converted_height = height;
    const int size = width * height * 4;
    std::memset(output, conversions % 256, size);
    return size;
  }

 private:
  int width_;
  int height_;
  VideoRotation rotation_;
};

class TestTrack : public libwebrtc::RTCVideoTrack {
 public:
  RTCTrackState state() const override { return kLive; }
  const libwebrtc::string kind() const override { return "video"; }
  const libwebrtc::string id() const override { return "test"; }
  bool enabled() const override { return true; }
  bool set_enabled(bool) override { return true; }
  void AddRenderer(libwebrtc::RTCVideoRenderer<
                   libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame>>*) override {}
  void RemoveRenderer(libwebrtc::RTCVideoRenderer<
                      libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame>>*) override {}
};

}  // namespace

std::unique_ptr<EventChannelProxy> EventChannelProxy::Create(
    BinaryMessenger*, TaskRunner*, const std::string&) {
  return std::make_unique<TestEvents>();
}

int main() {
  using namespace libwebrtc;
  using namespace flutter_webrtc_plugin;
  TestTextures textures;
  scoped_refptr<FlutterVideoRenderer> renderer = new RefCountedObject<FlutterVideoRenderer>();
  renderer->initialize(&textures, nullptr, nullptr, nullptr, 7);
  assert(renderer->CopyPixelBuffer(0, 0) == nullptr);

  for (const auto rotation : {RTCVideoFrame::kVideoRotation_0,
                              RTCVideoFrame::kVideoRotation_90,
                              RTCVideoFrame::kVideoRotation_180,
                              RTCVideoFrame::kVideoRotation_270}) {
    scoped_refptr<TestFrame> frame = new RefCountedObject<TestFrame>(640, 360, rotation);
    renderer->OnFrame(frame);
    const auto* pixels = renderer->CopyPixelBuffer(0, 0);
    const bool quarter_turn = rotation == 90 || rotation == 270;
    assert(pixels != nullptr);
    assert(pixels->width == (quarter_turn ? 360 : 640));
    assert(pixels->height == (quarter_turn ? 640 : 360));
    assert(frame->converted_width == static_cast<int>(pixels->width));
    assert(frame->converted_height == static_cast<int>(pixels->height));
    const auto* buffer = pixels->buffer;
    for (int read = 0; read < 5; ++read) {
      assert(renderer->CopyPixelBuffer(0, 0)->buffer == buffer);
    }
    assert(frame->conversions == 1);

    // Some producers reuse a frame object. Every OnFrame must invalidate pixels.
    renderer->OnFrame(frame);
    renderer->CopyPixelBuffer(0, 0);
    assert(frame->conversions == 2);
  }

  scoped_refptr<TestTrack> first_track = new RefCountedObject<TestTrack>();
  scoped_refptr<TestTrack> second_track = new RefCountedObject<TestTrack>();
  renderer->SetVideoTrack(first_track);
  renderer->OnFrame(new RefCountedObject<TestFrame>(640, 360,
      RTCVideoFrame::kVideoRotation_270));
  assert(emitted_rotations.back() == 270);
  const auto event_count = emitted_rotations.size();
  renderer->SetVideoTrack(second_track);
  renderer->OnFrame(new RefCountedObject<TestFrame>(640, 360,
      RTCVideoFrame::kVideoRotation_0));
  assert(emitted_rotations.size() == event_count + 1);
  assert(emitted_rotations.back() == 0);
  renderer->SetVideoTrack(nullptr);
  assert(renderer->CopyPixelBuffer(0, 0) == nullptr);
  renderer->SetVideoTrack(first_track);
  renderer->OnFrame(new RefCountedObject<TestFrame>(640, 360,
      RTCVideoFrame::kVideoRotation_270));
  assert(emitted_rotations.back() == 270);

  // Exercise repeated raster reads with a 1080p buffer. This measures duplicate
  // conversion requests, independent of a device's hardware decoder or frame rate.
  scoped_refptr<TestFrame> frame = new RefCountedObject<TestFrame>(1920, 1080,
      RTCVideoFrame::kVideoRotation_0);
  const auto started = std::chrono::steady_clock::now();
  for (int video_frame = 0; video_frame < 120; ++video_frame) {
    renderer->OnFrame(frame);
    for (int raster_read = 0; raster_read < 4; ++raster_read) {
      const auto* pixels = renderer->CopyPixelBuffer(0, 0);
      assert(pixels->buffer[0] == static_cast<uint8_t>(video_frame + 1));
    }
  }
  assert(frame->conversions == 120);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started).count();
  std::cout << "Native renderer: all rotations preserve dimensions; 480 raster "
               "reads / 120 frames = " << frame->conversions << " conversions ("
            << elapsed << " ms, synthetic 1080p buffer).\n";
}
