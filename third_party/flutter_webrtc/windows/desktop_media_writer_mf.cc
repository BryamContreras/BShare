#include "desktop_media_writer.h"

#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>

namespace bshare::media {
namespace {
using Microsoft::WRL::ComPtr;

std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                      static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring value(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), value.data(), size);
  return value;
}
std::string Utf8(const wchar_t* text) {
  if (!text) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string value(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, value.data(), size, nullptr, nullptr);
  value.pop_back();
  return value;
}
bool Check(HRESULT result, std::string& error) {
  if (SUCCEEDED(result)) return true;
  char message[96]{};
  std::snprintf(message, sizeof(message), "Windows media encoder error 0x%08lx",
                 static_cast<unsigned long>(result));
  error = message;
  return false;
}
uint8_t Byte(int value) { return static_cast<uint8_t>(std::clamp(value, 0, 255)); }

class MfWriter final : public IRawMediaWriter {
 public:
  ~MfWriter() override {
    writer_.Reset();
    if (mf_started_) MFShutdown();
    if (com_started_) CoUninitialize();
  }
  bool Start(const std::string& path, int width, int height, int fps,
             std::string& error) override {
    if (writer_ || width < 2 || height < 2 || (width & 1) || (height & 1) ||
        width > 4096 || height > 4096 || fps < 1 || fps > 60) {
      error = "Invalid recording dimensions or frame rate"; return false;
    }
    const auto wide_path = Wide(path);
    if (wide_path.empty()) { error = "Invalid recording path"; return false; }
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (!Check(com, error)) return false;
    com_started_ = true;
    if (!Check(MFStartup(MF_VERSION, MFSTARTUP_LITE), error)) return false;
    mf_started_ = true;
    width_ = width; height_ = height; fps_ = fps;
    ComPtr<IMFAttributes> attributes;
    if (!Check(MFCreateAttributes(&attributes, 3), error) ||
        !Check(attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE), error) ||
        !Check(attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE), error) ||
        !Check(MFCreateSinkWriterFromURL(wide_path.c_str(), nullptr, attributes.Get(), &writer_), error)) return false;
    ComPtr<IMFMediaType> video_output;
    ComPtr<IMFMediaType> video_input;
    if (!Check(MFCreateMediaType(&video_output), error) ||
        !Check(video_output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), error) ||
        !Check(video_output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264), error) ||
        !Check(video_output->SetUINT32(MF_MT_AVG_BITRATE,
          static_cast<UINT32>(std::clamp<int64_t>(static_cast<int64_t>(width) * height * fps / 6, 1500000, 24000000))), error) ||
        !VideoType(video_output.Get(), error) ||
        !Check(writer_->AddStream(video_output.Get(), &video_stream_), error) ||
        !Check(MFCreateMediaType(&video_input), error) ||
        !Check(video_input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), error) ||
        !Check(video_input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12), error) ||
        !VideoType(video_input.Get(), error) ||
        !Check(video_input->SetUINT32(MF_MT_DEFAULT_STRIDE, width), error) ||
        !Check(writer_->SetInputMediaType(video_stream_, video_input.Get(), nullptr), error)) return false;
    ComPtr<IMFMediaType> audio_output;
    ComPtr<IMFMediaType> audio_input;
    if (!Check(MFCreateMediaType(&audio_output), error) ||
        !Check(audio_output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), error) ||
        !Check(audio_output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC), error) ||
        !AudioType(audio_output.Get(), error) ||
        !Check(audio_output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000), error) ||
        !Check(audio_output->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0), error) ||
        !Check(writer_->AddStream(audio_output.Get(), &audio_stream_), error) ||
        !Check(MFCreateMediaType(&audio_input), error) ||
        !Check(audio_input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), error) ||
        !Check(audio_input->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM), error) ||
        !AudioType(audio_input.Get(), error) ||
        !Check(audio_input->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4), error) ||
        !Check(audio_input->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000), error) ||
        !Check(writer_->SetInputMediaType(audio_stream_, audio_input.Get(), nullptr), error) ||
        !Check(writer_->BeginWriting(), error)) return false;
    pixels_.resize(static_cast<size_t>(width) * height * 3 / 2);
    return true;
  }
  bool WriteVideo(const VideoFrame& frame, std::string& error) override {
    if (!writer_ || frame.width != width_ || frame.height != height_ ||
        frame.stride < width_ * 4 || frame.pts_us < 0 ||
        frame.bgra.size() < static_cast<size_t>(frame.stride) * height_) {
      error = "Invalid recording video frame"; return false;
    }
    auto* chroma = pixels_.data() + static_cast<size_t>(width_) * height_;
    for (int y = 0; y < height_; y += 2) {
      for (int x = 0; x < width_; x += 2) {
        int r = 0, g = 0, b = 0;
        for (int dy = 0; dy < 2; ++dy) {
          for (int dx = 0; dx < 2; ++dx) {
            const auto* pixel = frame.bgra.data() + static_cast<size_t>(y + dy) * frame.stride + (x + dx) * 4;
            pixels_[static_cast<size_t>(y + dy) * width_ + x + dx] = Byte(((47 * pixel[2] + 157 * pixel[1] + 16 * pixel[0] + 128) >> 8) + 16);
            r += pixel[2]; g += pixel[1]; b += pixel[0];
          }
        }
        r /= 4; g /= 4; b /= 4;
        chroma[static_cast<size_t>(y / 2) * width_ + x] = Byte(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128);
        chroma[static_cast<size_t>(y / 2) * width_ + x + 1] = Byte(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128);
      }
    }
    return Write(video_stream_, pixels_.data(), pixels_.size(), frame.pts_us * 10,
                  10000000LL / fps_, error);
  }
  bool WriteAudio(const AudioFrame& frame, std::string& error) override {
    if (!writer_ || frame.sample_rate != 48000 || frame.channels != 2 || frame.pts_us < 0 ||
        frame.samples_s16.empty() || (frame.samples_s16.size() & 1)) {
      error = "Invalid recording audio frame"; return false;
    }
    return Write(audio_stream_, reinterpret_cast<const uint8_t*>(frame.samples_s16.data()),
                  frame.samples_s16.size() * sizeof(int16_t), frame.pts_us * 10,
                  static_cast<int64_t>(frame.samples_s16.size() / 2) * 10000000 / 48000, error);
  }
  bool Finish(std::string& error) override {
    if (!writer_) { error = "Recording was not started"; return false; }
    const HRESULT result = writer_->Finalize();
    writer_.Reset();
    return Check(result, error);
  }
 private:
  bool VideoType(IMFMediaType* type, std::string& error) {
    return Check(type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive), error) &&
      Check(MFSetAttributeSize(type, MF_MT_FRAME_SIZE, width_, height_), error) &&
      Check(MFSetAttributeRatio(type, MF_MT_FRAME_RATE, fps_, 1), error) &&
      Check(MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1), error) &&
      Check(type->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709), error) &&
      Check(type->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235), error);
  }
  bool AudioType(IMFMediaType* type, std::string& error) {
    return Check(type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2), error) &&
      Check(type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000), error) &&
      Check(type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), error);
  }
  bool Write(DWORD stream, const uint8_t* bytes, size_t length, int64_t pts,
              int64_t duration, std::string& error) {
    if (length > std::numeric_limits<DWORD>::max()) { error = "Recording sample too large"; return false; }
    ComPtr<IMFMediaBuffer> buffer;
    ComPtr<IMFSample> sample;
    if (!Check(MFCreateMemoryBuffer(static_cast<DWORD>(length), &buffer), error)) return false;
    BYTE* destination = nullptr;
    if (!Check(buffer->Lock(&destination, nullptr, nullptr), error)) return false;
    std::memcpy(destination, bytes, length);
    buffer->Unlock();
    return Check(buffer->SetCurrentLength(static_cast<DWORD>(length)), error) &&
      Check(MFCreateSample(&sample), error) && Check(sample->AddBuffer(buffer.Get()), error) &&
      Check(sample->SetSampleTime(pts), error) && Check(sample->SetSampleDuration(duration), error) &&
      Check(writer_->WriteSample(stream, sample.Get()), error);
  }
  bool com_started_ = false;
  bool mf_started_ = false;
  int width_ = 0, height_ = 0, fps_ = 30;
  DWORD video_stream_ = 0, audio_stream_ = 0;
  ComPtr<IMFSinkWriter> writer_;
  std::vector<uint8_t> pixels_;
};
}  // namespace

std::unique_ptr<IRawMediaWriter> CreatePlatformMediaWriter() { return std::make_unique<MfWriter>(); }

bool WritePlatformPhotoJpeg(const std::string& path, const VideoFrame& frame,
                            double quality, std::string& error) {
  if (frame.width < 1 || frame.height < 1 || frame.stride < frame.width * 4 ||
      frame.width > 8192 || frame.height > 8192 ||
      frame.bgra.size() < static_cast<size_t>(frame.stride) * frame.height) {
    error = "Invalid photograph frame"; return false;
  }
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (!Check(com, error)) return false;
  bool success = false;
  {
    ComPtr<IWICImagingFactory> factory;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> output;
    ComPtr<IPropertyBag2> properties;
    auto process = [&]() {
      const auto wide_path = Wide(path);
      if (wide_path.empty()) { error = "Invalid photograph path"; return false; }
      if (!Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)), error) ||
          !Check(factory->CreateStream(&stream), error) ||
          !Check(stream->InitializeFromFilename(wide_path.c_str(), GENERIC_WRITE), error) ||
          !Check(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder), error) ||
          !Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache), error) ||
          !Check(encoder->CreateNewFrame(&output, &properties), error)) return false;
      PROPBAG2 option{}; option.pstrName = const_cast<wchar_t*>(L"ImageQuality");
      VARIANT value{}; value.vt = VT_R4; value.fltVal = static_cast<float>(std::clamp(quality, 0.0, 1.0));
      WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
      if (!Check(properties->Write(1, &option, &value), error) ||
          !Check(output->Initialize(properties.Get()), error) ||
          !Check(output->SetSize(frame.width, frame.height), error) ||
          !Check(output->SetPixelFormat(&format), error) || format != GUID_WICPixelFormat24bppBGR) return false;
      const UINT stride = static_cast<UINT>(frame.width * 3);
      std::vector<uint8_t> pixels(static_cast<size_t>(stride) * frame.height);
      for (int y = 0; y < frame.height; ++y) {
        for (int x = 0; x < frame.width; ++x) {
          const auto* source = frame.bgra.data() + static_cast<size_t>(y) * frame.stride + x * 4;
          auto* destination = pixels.data() + static_cast<size_t>(y) * stride + x * 3;
          destination[0] = source[0]; destination[1] = source[1]; destination[2] = source[2];
        }
      }
      return Check(output->WritePixels(frame.height, stride, static_cast<UINT>(pixels.size()), pixels.data()), error) &&
        Check(output->Commit(), error) && Check(encoder->Commit(), error);
    };
    success = process();
  }
  CoUninitialize();
  return success;
}

std::pair<std::string, std::string> PlatformMediaDirectories() {
  auto directory = [](REFKNOWNFOLDERID id) {
    PWSTR path = nullptr;
    if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &path))) return std::string{};
    const auto result = Utf8(path); CoTaskMemFree(path); return result;
  };
  return {directory(FOLDERID_Pictures), directory(FOLDERID_Videos)};
}
}  // namespace bshare::media
