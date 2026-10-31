#pragma once

#include "transport.h"
#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace bshare::virtual_camera {
// Matches the Windows publisher API. The WebRTC callback never waits for a
// daemon, a device, IPC backpressure, or a cross-process lock.
class FramePublisher {
 public:
  FramePublisher() : worker_([this] { Run(); }) {}
  ~FramePublisher() {
    stopping_ = true;
    wake_.notify_all();
    if (worker_.joinable()) worker_.join();
  }
  bool IsReady() const { return connected_.load(); }
  void Publish(const uint8_t* pixels, int width, int height, int stride) {
    if (!pixels || !IsReady() || width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
        stride < width * 4 || uint64_t(stride) * height > kMaxFrameBytes) return;
    auto frame = std::make_shared<Frame>();
    frame->width = width; frame->height = height; frame->stride = width * 4;
    frame->pixels.resize(size_t(frame->stride) * height);
    for (int row = 0; row < height; ++row)
      memcpy(frame->pixels.data() + size_t(row) * frame->stride, pixels + size_t(row) * stride, frame->stride);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      latest_ = std::move(frame);
      generation_++;
    }
    wake_.notify_all();
  }
  void Clear() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      latest_.reset();
      generation_++;
    }
    wake_.notify_all();
  }
 private:
  struct Frame { uint32_t width, height, stride; std::vector<uint8_t> pixels; };
  std::atomic<bool> stopping_{false}, connected_{false};
  std::atomic<uint64_t> generation_{0};
  std::mutex mutex_;
  std::condition_variable wake_;
  std::shared_ptr<Frame> latest_;
  std::thread worker_;

  bool WaitForSocket(int socket, short events, int timeout) {
    // Destruction can occur on the video callback when a renderer is removed.
    // Bound cancellation latency even when a stalled peer never acknowledges.
    const uint64_t deadline = MonotonicMilliseconds() + timeout;
    while (!stopping_ && MonotonicMilliseconds() < deadline) {
      pollfd event{socket, events, 0};
      const int result = poll(&event, 1, 5);
      if (result > 0) return (event.revents & events) != 0;
      if (result < 0 && errno != EINTR) return false;
    }
    return false;
  }
  int Connect(SharedMemory& memory) {
    sockaddr_un address{};
    if (!SocketAddress(RuntimeDirectory(false), &address)) return -1;
    int socket = ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (socket < 0) return -1;
    auto fail = [&] { close(socket); return -1; };
    if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address))) {
      if (errno != EINPROGRESS) return fail();
      if (!WaitForSocket(socket, POLLOUT, 100)) return fail();
      int error = 0; socklen_t size = sizeof(error);
      if (getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) || error) return fail();
    }
    ucred peer{}; socklen_t peer_size = sizeof(peer);
    if (getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &peer, &peer_size) || peer.uid != geteuid()) return fail();
    if (!SendMemory(socket, memory.fd)) return fail();
    uint32_t acknowledgement[2]{};
    if (!WaitForSocket(socket, POLLIN, 250) || recv(socket, acknowledgement, sizeof(acknowledgement), 0) != sizeof(acknowledgement) ||
        acknowledgement[0] != kMagic || acknowledgement[1] != kVersion) return fail();
    return socket;
  }
  void Run() {
    SharedMemory memory;
    if (!memory.Create()) return;
    int socket = -1;
    uint64_t published_generation = UINT64_MAX;
    while (!stopping_) {
      bool busy = false;
      if (socket < 0) {
        socket = Connect(memory);
        connected_ = socket >= 0;
        published_generation = UINT64_MAX;
      }
      if (socket >= 0) {
        pollfd event{socket, POLLIN | POLLHUP | POLLERR, 0};
        if (poll(&event, 1, 0) > 0) {
          close(socket); socket = -1; connected_ = false;
        } else if (LockShared(memory.header)) {
          std::shared_ptr<Frame> frame;
          uint64_t generation;
          {
            std::lock_guard<std::mutex> lock(mutex_);
            frame = latest_;
            generation = generation_;
          }
          if (published_generation != generation) {
            memory.header->valid = 0;
            if (frame) {
              memory.header->width = frame->width; memory.header->height = frame->height;
              memory.header->stride = frame->stride; memory.header->bytes = frame->pixels.size();
              memcpy(memory.pixels(), frame->pixels.data(), frame->pixels.size());
              memory.header->valid = generation == generation_.load();
            }
            memory.header->sequence++;
            published_generation = generation;
          }
          memory.header->heartbeat = MonotonicMilliseconds();
          pthread_mutex_unlock(&memory.header->guard);
        } else busy = true;
      }
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait_for(lock, std::chrono::milliseconds(busy ? 2 : socket < 0 ? 500 : 250), [&] {
        return stopping_ || (!busy && socket >= 0 && generation_ != published_generation);
      });
    }
    connected_ = false;
    if (LockShared(memory.header)) {
      memory.header->valid = 0;
      pthread_mutex_unlock(&memory.header->guard);
    }
    if (socket >= 0) close(socket);
  }
};
}  // namespace bshare::virtual_camera
