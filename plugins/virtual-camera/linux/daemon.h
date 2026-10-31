#pragma once
#include "frame_output.h"
#include <atomic>
#include <functional>
#include <sys/file.h>
#include <thread>

namespace bshare::virtual_camera {
class FrameSink {
 public:
  virtual ~FrameSink() = default;
  virtual bool Open() = 0;
  virtual bool Write(const uint8_t* bytes, size_t size) = 0;
  virtual void Close() = 0;
};

class CameraDaemon {
 public:
  CameraDaemon(FrameSink& sink, std::function<bool()> active)
      : sink_(sink), active_(std::move(active)), idle_(WaitingImage()) {}
  ~CameraDaemon() { Stop(); }
  void Stop() { stopping_ = true; }
  bool output_ready() const { return output_ready_; }
  bool producer_active() const { return producer_active_; }
  bool Run() {
    const std::string directory = RuntimeDirectory(true);
    sockaddr_un address{};
    if (!SocketAddress(directory, &address)) return false;
    const std::string lock_path = directory + "/daemon.lock";
    int lock = open(lock_path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    struct stat info{};
    if (lock < 0 || fstat(lock, &info) || info.st_uid != geteuid() ||
        !S_ISREG(info.st_mode) || (info.st_mode & 0077) || flock(lock, LOCK_EX | LOCK_NB)) {
      if (lock >= 0) close(lock);
      return false;
    }
    if (!lstat(address.sun_path, &info)) {
      if (!S_ISSOCK(info.st_mode) || info.st_uid != geteuid()) { close(lock); return false; }
      unlink(address.sun_path);
    }
    int listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    const mode_t old_mask = umask(0077);
    const bool bound = listener >= 0 && !bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address));
    umask(old_mask);
    if (!bound || listen(listener, 4)) {
      if (listener >= 0) close(listener);
      close(lock); return false;
    }
    int client = -1;
    SharedMemory memory;
    PixelFrame frame;
    std::vector<uint8_t> live;
    uint64_t sequence = UINT64_MAX, last_video = 0, last_check = 0, opening_until = 0;
    bool active = false, has_live = false;
    auto disconnect = [&] {
      if (client >= 0) close(client);
      client = -1; memory.Reset(); producer_active_ = false;
      sequence = UINT64_MAX; has_live = false;
    };
    auto tick = std::chrono::steady_clock::now();
    while (!stopping_) {
      const auto now = MonotonicMilliseconds();
      if (now - last_check >= 1000) {
        last_check = now; active = active_();
        if (!active) {
          disconnect(); sink_.Close(); output_ready_ = false;
        } else if (!output_ready_) {
          output_ready_ = sink_.Open();
        }
        WriteStatus(directory, active, has_live);
      }
      pollfd events[2]{{listener, POLLIN, 0}, {client, POLLIN | POLLHUP | POLLERR, 0}};
      if (poll(events, client >= 0 ? 2 : 1, 0) > 0) {
        if (events[0].revents & POLLIN) {
          int incoming = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
          ucred peer{}; socklen_t length = sizeof(peer);
          if (incoming >= 0) {
            if (client >= 0 || !active || !output_ready_ ||
                getsockopt(incoming, SOL_SOCKET, SO_PEERCRED, &peer, &length) || peer.uid != geteuid()) close(incoming);
            else { client = incoming; opening_until = now + 1000; }
          }
        }
        if (client >= 0 && events[1].fd == client && events[1].revents) {
          if (events[1].revents & (POLLHUP | POLLERR)) disconnect();
          else if (events[1].revents & POLLIN) {
            if (memory.header) disconnect(); // Exactly one descriptor/handshake per producer.
            else {
              const int descriptor = ReceiveMemory(client);
              if (descriptor < 0 || !memory.Adopt(descriptor)) disconnect();
              else {
                const uint32_t reply[]{kMagic, kVersion};
                if (send(client, reply, sizeof(reply), MSG_NOSIGNAL) != sizeof(reply)) disconnect();
                else producer_active_ = true;
              }
            }
          }
        }
      }
      if (client >= 0 && !memory.header && now >= opening_until) disconnect();
      if (memory.header && LockShared(memory.header)) {
        const auto& header = *memory.header;
        const bool valid = header.valid && header.heartbeat <= now + 100 &&
            now <= header.heartbeat + 1500 && header.width > 0 && header.width <= 4096 &&
            header.height > 0 && header.height <= 4096 && header.stride >= header.width * 4 &&
            uint64_t(header.stride) * header.height == header.bytes && header.bytes <= kMaxFrameBytes;
        if (!valid) has_live = false;
        else {
          last_video = now;
          if (header.sequence != sequence) {
            frame.width = header.width; frame.height = header.height; frame.stride = header.stride;
            frame.pixels.resize(header.bytes);
            memcpy(frame.pixels.data(), memory.pixels(), header.bytes);
            sequence = header.sequence;
            pthread_mutex_unlock(&memory.header->guard);
            BgraToYuyv(frame, live);
            has_live = true;
            goto render;
          }
        }
        pthread_mutex_unlock(&memory.header->guard);
      }
      if (now > last_video + 1500) has_live = false;
render:
      if (output_ready_) {
        const auto& pixels = has_live ? live : idle_;
        if (!sink_.Write(pixels.data(), pixels.size())) {
          sink_.Close(); output_ready_ = false; disconnect();
        }
      }
      tick += std::chrono::microseconds(33333);
      const auto current = std::chrono::steady_clock::now();
      if (tick < current) tick = current;
      std::this_thread::sleep_until(tick);
    }
    disconnect(); sink_.Close(); output_ready_ = false;
    close(listener); unlink(address.sun_path); close(lock);
    unlink((directory + "/status.json").c_str());
    return true;
  }
 private:
  FrameSink& sink_;
  std::function<bool()> active_;
  std::vector<uint8_t> idle_;
  std::atomic<bool> stopping_{false}, output_ready_{false}, producer_active_{false};
  void WriteStatus(const std::string& directory, bool active, bool live) {
    const std::string path = directory + "/status.json";
    const std::string temporary = directory + "/.status-" + std::to_string(getpid());
    int file = open(temporary.c_str(), O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (file < 0) return;
    const std::string value = "{\"pid\":" + std::to_string(getpid()) +
        ",\"heartbeat\":" + std::to_string(MonotonicMilliseconds()) +
        ",\"ready\":" + (output_ready_ ? "true" : "false") +
        ",\"activeUser\":" + (active ? "true" : "false") +
        ",\"producerActive\":" + (producer_active_ ? "true" : "false") +
        ",\"liveVideo\":" + (live ? "true" : "false") + "}\n";
    const auto written = write(file, value.data(), value.size());
    close(file);
    if (written == static_cast<ssize_t>(value.size())) rename(temporary.c_str(), path.c_str());
    else unlink(temporary.c_str());
  }
};
}  // namespace bshare::virtual_camera
