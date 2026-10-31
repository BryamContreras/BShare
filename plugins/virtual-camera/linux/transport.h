#pragma once

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <fcntl.h>
#include <linux/memfd.h>
#include <poll.h>
#include <new>
#include <pthread.h>
#include <string>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

namespace bshare::virtual_camera {
constexpr uint32_t kMagic = 0x42534832;
constexpr uint32_t kVersion = 1;
constexpr uint32_t kMaxFrameBytes = 32 * 1024 * 1024;
constexpr const char* kDeviceName = "BShare Virtual Camera";

inline uint64_t MonotonicMilliseconds() {
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  return uint64_t(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
}

struct SharedHeader {
  uint32_t magic = kMagic;
  uint32_t version = kVersion;
  uint32_t header_bytes = sizeof(SharedHeader);
  uint32_t capacity = kMaxFrameBytes;
  pthread_mutex_t guard;
  uint64_t heartbeat = 0;
  uint64_t sequence = 0;
  uint32_t width = 0, height = 0, stride = 0, bytes = 0, valid = 0;
};
constexpr size_t kMapBytes = sizeof(SharedHeader) + kMaxFrameBytes;

inline bool LockShared(SharedHeader* header) {
  const int result = pthread_mutex_trylock(&header->guard);
  if (result == EOWNERDEAD) {
    header->valid = 0;
    pthread_mutex_consistent(&header->guard);
    return true;
  }
  return result == 0;
}

inline std::string RuntimeDirectory(bool create) {
  const char* configured = getenv("XDG_RUNTIME_DIR");
  const std::string base = configured ? configured : "/run/user/" + std::to_string(geteuid());
  struct stat info{};
  if (base.empty() || base.front() != '/' || lstat(base.c_str(), &info) ||
      !S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0022)) return {};
  const std::string directory = base + "/bshare-virtual-camera";
  if (create && mkdir(directory.c_str(), 0700) && errno != EEXIST) return {};
  if (lstat(directory.c_str(), &info) || !S_ISDIR(info.st_mode) ||
      info.st_uid != geteuid() || (info.st_mode & 0077)) return {};
  return directory;
}

inline bool SocketAddress(const std::string& directory, sockaddr_un* address) {
  const std::string path = directory + "/frames.sock";
  if (directory.empty() || path.size() >= sizeof(address->sun_path)) return false;
  *address = {};
  address->sun_family = AF_UNIX;
  memcpy(address->sun_path, path.c_str(), path.size() + 1);
  return true;
}

struct SharedMemory {
  int fd = -1;
  SharedHeader* header = nullptr;
  ~SharedMemory() { Reset(); }
  void Reset() {
    if (header) munmap(header, kMapBytes);
    if (fd >= 0) close(fd);
    header = nullptr;
    fd = -1;
  }
  uint8_t* pixels() { return reinterpret_cast<uint8_t*>(header) + sizeof(SharedHeader); }
  bool Create() {
    fd = static_cast<int>(syscall(SYS_memfd_create, "bshare-video", MFD_CLOEXEC | MFD_ALLOW_SEALING));
    if (fd < 0 || ftruncate(fd, kMapBytes)) { Reset(); return false; }
    void* mapped = mmap(nullptr, kMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) { Reset(); return false; }
    header = new(mapped) SharedHeader();
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    const bool okay = !pthread_mutexattr_setpshared(&attributes, PTHREAD_PROCESS_SHARED) &&
        !pthread_mutexattr_setrobust(&attributes, PTHREAD_MUTEX_ROBUST) &&
        !pthread_mutex_init(&header->guard, &attributes);
    pthread_mutexattr_destroy(&attributes);
    if (!okay || fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL)) {
      Reset(); return false;
    }
    return true;
  }
  bool Adopt(int descriptor) {
    Reset();
    fd = descriptor;
    struct stat info{};
    const int seals = fcntl(fd, F_GET_SEALS);
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != geteuid() ||
        info.st_size != static_cast<off_t>(kMapBytes) || seals < 0 ||
        (seals & (F_SEAL_SHRINK | F_SEAL_GROW)) != (F_SEAL_SHRINK | F_SEAL_GROW)) {
      Reset(); return false;
    }
    void* mapped = mmap(nullptr, kMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) { Reset(); return false; }
    header = static_cast<SharedHeader*>(mapped);
    if (header->magic != kMagic || header->version != kVersion ||
        header->header_bytes != sizeof(SharedHeader) || header->capacity != kMaxFrameBytes) {
      Reset(); return false;
    }
    return true;
  }
};

inline bool SendMemory(int socket, int fd) {
  const uint32_t hello[]{kMagic, kVersion};
  iovec io{const_cast<uint32_t*>(hello), sizeof(hello)};
  alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))]{};
  msghdr message{};
  message.msg_iov = &io; message.msg_iovlen = 1;
  message.msg_control = control; message.msg_controllen = sizeof(control);
  auto* item = CMSG_FIRSTHDR(&message);
  item->cmsg_level = SOL_SOCKET; item->cmsg_type = SCM_RIGHTS;
  item->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(item), &fd, sizeof(fd));
  return sendmsg(socket, &message, MSG_NOSIGNAL) == sizeof(hello);
}

inline int ReceiveMemory(int socket) {
  uint32_t hello[2]{};
  iovec io{hello, sizeof(hello)};
  alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int) * 8)]{};
  msghdr message{};
  message.msg_iov = &io; message.msg_iovlen = 1;
  message.msg_control = control; message.msg_controllen = sizeof(control);
  const auto size = recvmsg(socket, &message, MSG_CMSG_CLOEXEC);
  int descriptor = -1, count = 0;
  for (auto* item = CMSG_FIRSTHDR(&message); item; item = CMSG_NXTHDR(&message, item)) {
    if (item->cmsg_level != SOL_SOCKET || item->cmsg_type != SCM_RIGHTS ||
        item->cmsg_len < CMSG_LEN(0)) continue;
    const size_t length = (item->cmsg_len - CMSG_LEN(0)) / sizeof(int);
    for (size_t i = 0; i < length; ++i) {
      int received;
      memcpy(&received, CMSG_DATA(item) + i * sizeof(int), sizeof(int));
      if (++count == 1) descriptor = received;
      else close(received);
    }
  }
  if (size != sizeof(hello) || hello[0] != kMagic || hello[1] != kVersion ||
      count != 1 || (message.msg_flags & (MSG_TRUNC | MSG_CTRUNC))) {
    if (descriptor >= 0) close(descriptor);
    return -1;
  }
  return descriptor;
}
}  // namespace bshare::virtual_camera
