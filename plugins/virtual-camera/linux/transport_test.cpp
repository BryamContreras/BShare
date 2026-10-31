#include "bshare_frame_publisher_linux.h"
#include "v4l2_output.h"
#include <cassert>
#include <filesystem>
#include <iostream>
#include <sys/wait.h>

using namespace bshare::virtual_camera;
namespace {
uint64_t Hash(const uint8_t* bytes, size_t size) {
  uint64_t hash = 1469598103934665603ULL;
  for (size_t index = 0; index < size; index += 97) hash = (hash ^ bytes[index]) * 1099511628211ULL;
  return hash;
}
class TestSink : public FrameSink {
 public:
  std::atomic<uint64_t> frames{0}, hash{0};
  std::atomic<int> opens{0}, closes{0};
  bool opened = false;
  bool Open() override { opened = true; ++opens; return true; }
  bool Write(const uint8_t* bytes, size_t size) override {
    if (!opened || size != kOutputBytes) return false;
    hash = Hash(bytes, size); ++frames; return true;
  }
  void Close() override { if (opened) ++closes; opened = false; }
};
template<class Predicate> void Wait(Predicate check) {
  for (int attempt = 0; attempt < 400; ++attempt) {
    if (check()) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  assert(check());
}
void DeviceGuards() {
  std::string driver = "uvcvideo", card = kDeviceName;
  int formats = 0, writes = 0, closes = 0;
  VideoOperations operations;
  operations.open = [](const char*, int) { return 73; };
  operations.stat = [](int, struct stat* info) {
    *info = {}; info->st_mode = S_IFCHR; info->st_rdev = makedev(81, 1); return 0;
  };
  operations.lock = [](int, int) { return 0; };
  operations.close = [&](int) { ++closes; return 0; };
  operations.write = [&](int, const void*, size_t count) { ++writes; return static_cast<ssize_t>(count); };
  operations.control = [&](int, unsigned long request, void* value) {
    if (request == VIDIOC_QUERYCAP) {
      auto* capability = static_cast<v4l2_capability*>(value);
      *capability = {};
      memcpy(capability->driver, driver.c_str(), driver.size());
      memcpy(capability->card, card.c_str(), card.size());
      return 0;
    }
    if (request == VIDIOC_QUERYCTRL) {
      auto* control = static_cast<v4l2_queryctrl*>(value);
      const uint32_t id = control->id & ~V4L2_CTRL_FLAG_NEXT_CTRL;
      if (id >= 3) { errno = EINVAL; return -1; }
      const char* names[]{"keep_format", "sustain_framerate", "timeout"};
      control->id = id + 1;
      memcpy(control->name, names[id], strlen(names[id]) + 1);
      return 0;
    }
    if (request == VIDIOC_S_FMT) {
      auto* format = static_cast<v4l2_format*>(value);
      assert(format->type == V4L2_BUF_TYPE_VIDEO_OUTPUT);
      assert(format->fmt.pix.width == 1280 && format->fmt.pix.height == 720);
      assert(format->fmt.pix.pixelformat == V4L2_PIX_FMT_YUYV);
      ++formats;
      return 0;
    }
    return 0;
  };
  V4l2Sink device([] { return "/dev/video63"; }, operations);
  assert(!device.Open()); // A physical camera with a similar label is never configured.
  assert(formats == 0 && writes == 0);
  driver = "v4l2 loopback"; card = "OBS Virtual Camera";
  assert(!device.Open()); // Never configure someone else's loopback camera.
  assert(formats == 0 && writes == 0);
  card = kDeviceName;
  assert(device.Open());
  assert(formats == 1);
  const auto waiting = WaitingImage();
  assert(device.Write(waiting.data(), waiting.size()));
  assert(writes == 1);
  device.Close();
  assert(closes == 3);
}
}

int main() {
  DeviceGuards();
  { // An interrupted writer cannot deadlock the next reader across processes.
    SharedMemory shared;
    assert(shared.Create());
    assert(ftruncate(shared.fd, 4) < 0 && errno == EPERM);
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
      assert(!pthread_mutex_lock(&shared.header->guard));
      shared.header->valid = 1;
      _exit(0);
    }
    assert(waitpid(child, nullptr, 0) == child);
    assert(LockShared(shared.header));
    assert(shared.header->valid == 0);
    pthread_mutex_unlock(&shared.header->guard);
  }
  SharedMemory invalid;
  int tiny = static_cast<int>(syscall(SYS_memfd_create, "invalid-video", MFD_CLOEXEC | MFD_ALLOW_SEALING));
  assert(tiny >= 0); assert(!ftruncate(tiny, 4));
  assert(!invalid.Adopt(tiny)); // Closes the rejected descriptor too.
  char directory[] = "/tmp/bshare-vcamera-test-XXXXXX";
  assert(mkdtemp(directory));
  assert(!setenv("XDG_RUNTIME_DIR", directory, 1));
  assert(!RuntimeDirectory(true).empty());
  assert(!chmod(directory, 0777));
  assert(RuntimeDirectory(false).empty());
  assert(!chmod(directory, 0700));
  const auto runtime = std::string(directory) + "/bshare-virtual-camera";
  std::filesystem::rename(runtime, runtime + "-saved");
  assert(!symlink((runtime + "-saved").c_str(), runtime.c_str()));
  assert(RuntimeDirectory(false).empty());
  assert(!unlink(runtime.c_str()));
  std::filesystem::rename(runtime + "-saved", runtime);
  TestSink sink;
  std::atomic<bool> active{true};
  CameraDaemon daemon(sink, [&] { return active.load(); });
  bool ran = false;
  std::thread server([&] { ran = daemon.Run(); });
  Wait([&] { return sink.frames > 2; });
  const auto idle = sink.hash.load();
  assert(idle != 0 && sink.opens == 1);
  auto publisher = std::make_unique<FramePublisher>();
  Wait([&] { return publisher->IsReady(); });
  PixelFrame source;
  source.width = 2; source.height = 4; source.stride = 8;
  source.pixels.resize(32);
  for (size_t index = 0; index < source.pixels.size(); index += 4) {
    source.pixels[index] = index % 8 ? 255 : 0;
    source.pixels[index + 2] = index % 8 ? 0 : 255;
    source.pixels[index + 3] = 255;
  }
  std::vector<uint8_t> expected;
  BgraToYuyv(source, expected);
  const auto live = Hash(expected.data(), expected.size());
  assert(live != idle);
  publisher->Publish(source.pixels.data(), source.width, source.height, source.stride);
  Wait([&] { return sink.hash == live; });
  { // A second producer cannot replace an active session.
    FramePublisher second;
    std::this_thread::sleep_for(std::chrono::milliseconds(600));
    assert(!second.IsReady());
    assert(sink.hash == live);
  }
  publisher->Clear();
  Wait([&] { return sink.hash == idle; });
  publisher->Publish(source.pixels.data(), source.width, source.height, source.stride);
  Wait([&] { return sink.hash == live; });
  publisher.reset();
  Wait([&] { return sink.hash == idle; });
  const auto before = sink.frames.load();
  Wait([&] { return sink.frames > before + 3; });
  assert(sink.opens == 1 && sink.closes == 0); // Device stays open after app exit.
  active = false;
  Wait([&] { return sink.closes == 1; });
  active = true;
  Wait([&] { return sink.opens == 2 && sink.hash == idle; });
  daemon.Stop(); server.join();
  assert(ran && sink.closes == 2);
  assert(!std::filesystem::exists(std::string(directory) + "/bshare-virtual-camera/frames.sock"));
  const auto owned = std::filesystem::canonical(directory);
  assert(owned.parent_path() == "/tmp" && owned.filename().string().find("bshare-vcamera-test-") == 0);
  std::filesystem::remove_all(owned);
  std::cout << "Production Linux IPC/frames, idle continuity, exclusivity, UID/runtime guards and V4L2 ownership checks passed.\n";
}
