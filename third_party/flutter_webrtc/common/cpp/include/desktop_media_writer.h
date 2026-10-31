#ifndef BSHARE_DESKTOP_MEDIA_WRITER_H_
#define BSHARE_DESKTOP_MEDIA_WRITER_H_

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace bshare::media {

// All writer calls belong to one owned recording worker. Pixels are top-down
// BGRA, already rotated and fitted to the stable recording canvas. Audio is
// interleaved signed 16-bit PCM; the controller supplies 48 kHz stereo.
struct VideoFrame {
  int width = 0;
  int height = 0;
  int stride = 0;
  int64_t pts_us = 0;
  std::vector<uint8_t> bgra;
};
struct AudioFrame {
  int sample_rate = 48000;
  int channels = 2;
  int64_t pts_us = 0;
  std::vector<int16_t> samples_s16;
};

class IRawMediaWriter {
 public:
  virtual ~IRawMediaWriter() = default;
  virtual bool Start(const std::string& temporary_path, int width, int height,
                     int fps, std::string& error) = 0;
  virtual bool WriteVideo(const VideoFrame& frame, std::string& error) = 0;
  virtual bool WriteAudio(const AudioFrame& frame, std::string& error) = 0;
  virtual bool Finish(std::string& error) = 0;
};

std::unique_ptr<IRawMediaWriter> CreatePlatformMediaWriter();
bool WritePlatformPhotoJpeg(const std::string& temporary_path,
                            const VideoFrame& frame, double quality,
                            std::string& error);
// OS Pictures and Videos/Movies directories, before adding the BShare folder.
std::pair<std::string, std::string> PlatformMediaDirectories();

}  // namespace bshare::media
#endif
