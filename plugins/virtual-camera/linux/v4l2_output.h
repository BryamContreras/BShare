#pragma once
#include "daemon.h"
#include <filesystem>
#include <fstream>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/sysmacros.h>

namespace bshare::virtual_camera {
struct VideoOperations {
  std::function<int(const char*, int)> open = [](const char* path, int flags) { return ::open(path, flags); };
  std::function<int(int, unsigned long, void*)> control = [](int fd, unsigned long request, void* value) { return ioctl(fd, request, value); };
  std::function<int(int, struct stat*)> stat = [](int fd, struct stat* info) { return fstat(fd, info); };
  std::function<int(int, int)> lock = [](int fd, int operation) { return flock(fd, operation); };
  std::function<ssize_t(int, const void*, size_t)> write = [](int fd, const void* bytes, size_t size) { return ::write(fd, bytes, size); };
  std::function<int(int)> close = [](int fd) { return ::close(fd); };
};

inline bool OwnedDevice(int fd, VideoOperations& operations) {
  struct stat info{};
  v4l2_capability capability{};
  return !operations.stat(fd, &info) && S_ISCHR(info.st_mode) && major(info.st_rdev) == 81 &&
      !operations.control(fd, VIDIOC_QUERYCAP, &capability) &&
      std::string(reinterpret_cast<char*>(capability.driver), strnlen(reinterpret_cast<char*>(capability.driver), sizeof(capability.driver))) == "v4l2 loopback" &&
      std::string(reinterpret_cast<char*>(capability.card), strnlen(reinterpret_cast<char*>(capability.card), sizeof(capability.card))) == kDeviceName;
}

inline std::string FindDevice() {
  std::error_code error;
  const std::filesystem::path base("/sys/devices/virtual/video4linux");
  if (!std::filesystem::exists(base, error)) return {};
  for (const auto& entry : std::filesystem::directory_iterator(base, error)) {
    std::string label;
    std::ifstream input(entry.path() / "name");
    std::getline(input, label);
    if (label == kDeviceName) return "/dev/" + entry.path().filename().string();
  }
  return {};
}

class V4l2Sink : public FrameSink {
 public:
  explicit V4l2Sink(std::function<std::string()> device = FindDevice,
                    VideoOperations operations = {})
      : device_(std::move(device)), operations_(std::move(operations)) {}
  ~V4l2Sink() override { Close(); }
  bool Open() override {
    Close();
    const std::string path = device_();
    if (path.empty()) return false;
    fd_ = operations_.open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd_ < 0) return false;
    if (!OwnedDevice(fd_, operations_) || operations_.lock(fd_, LOCK_EX | LOCK_NB)) { Close(); return false; }
    SetControl("keep_format", 0);
    v4l2_format format{};
    format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    format.fmt.pix.width = kOutputWidth; format.fmt.pix.height = kOutputHeight;
    format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    format.fmt.pix.field = V4L2_FIELD_NONE;
    format.fmt.pix.bytesperline = kOutputWidth * 2; format.fmt.pix.sizeimage = kOutputBytes;
    format.fmt.pix.colorspace = V4L2_COLORSPACE_REC709;
    format.fmt.pix.ycbcr_enc = V4L2_YCBCR_ENC_709;
    format.fmt.pix.quantization = V4L2_QUANTIZATION_LIM_RANGE;
    if (operations_.control(fd_, VIDIOC_S_FMT, &format) ||
        format.fmt.pix.width != kOutputWidth || format.fmt.pix.height != kOutputHeight ||
        format.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV || format.fmt.pix.sizeimage != kOutputBytes) {
      Close(); return false;
    }
    v4l2_streamparm parameters{};
    parameters.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    parameters.parm.output.timeperframe = {1, 30};
    operations_.control(fd_, VIDIOC_S_PARM, &parameters);
    if (!SetControl("keep_format", 1)) { Close(); return false; }
    SetControl("sustain_framerate", 1);
    SetControl("timeout", 1500);
    return true;
  }
  bool Write(const uint8_t* bytes, size_t size) override {
    if (fd_ < 0 || size != kOutputBytes) return false;
    const auto result = operations_.write(fd_, bytes, size);
    return result == static_cast<ssize_t>(size) || (result < 0 && (errno == EAGAIN || errno == EINTR));
  }
  void Close() override { if (fd_ >= 0) operations_.close(fd_); fd_ = -1; }
 private:
  std::function<std::string()> device_;
  VideoOperations operations_;
  int fd_ = -1;
  bool SetControl(const std::string& name, int value) {
    v4l2_queryctrl query{};
    query.id = V4L2_CTRL_FLAG_NEXT_CTRL;
    for (int count = 0; count < 128 && !operations_.control(fd_, VIDIOC_QUERYCTRL, &query); ++count) {
      if (std::string(reinterpret_cast<char*>(query.name), strnlen(reinterpret_cast<char*>(query.name), sizeof(query.name))) == name) {
        v4l2_control setting{query.id, value};
        return !operations_.control(fd_, VIDIOC_S_CTRL, &setting);
      }
      query.id |= V4L2_CTRL_FLAG_NEXT_CTRL;
    }
    return false;
  }
};
}  // namespace bshare::virtual_camera
