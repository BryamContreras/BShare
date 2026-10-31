#pragma once
// BShare's private, local-only BGRA transport. No audio or app UI is exported.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <sddl.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace bshare::virtual_camera {
inline constexpr uint32_t kWireMagic = 0x42535643; // BSVC
inline constexpr uint32_t kMaxPixels = 4096 * 2160;
struct WireHeader {
  uint32_t magic = kWireMagic;
  uint32_t version = 1;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t bytes = 0; // zero is the explicit disconnected state
  uint32_t reserved = 0;
};
static_assert(sizeof(WireHeader) == 24);

inline std::wstring CurrentUserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return {};
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<uint8_t> buffer(size);
  bool ok = GetTokenInformation(token, TokenUser, buffer.data(), size, &size) != FALSE;
  CloseHandle(token);
  if (!ok) return {};
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) return {};
  std::wstring result(text);
  LocalFree(text);
  return result;
}
inline std::wstring PipeNameForSid(const std::wstring& sid) {
  return L"\\\\.\\pipe\\BShare.VirtualCamera.v1." + sid;
}
inline bool ValidCredential(const std::wstring& value) {
  return value.size() == 32 && std::all_of(value.begin(), value.end(), [](wchar_t c) {
    return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f');
  });
}
// The camera registration gets the same secret as its user's publisher. Other
// interactive users cannot register a source targeting this user's pixel pipe.
// Do not print this credential or include it in support reports.
inline std::wstring ProducerCredential(bool create = false) {
  const auto sid = CurrentUserSid();
  if (sid.empty()) return {};
  PSECURITY_DESCRIPTOR security = nullptr;
  auto descriptor = L"O:" + sid + L"D:P(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;" + sid + L")";
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor.c_str(), SDDL_REVISION_1, &security, nullptr)) return {};
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), security, FALSE};
  struct CreationLock {
    HANDLE handle = nullptr;
    bool held = false;
    ~CreationLock() { if (held) ReleaseMutex(handle); if (handle) CloseHandle(handle); }
  } creation_lock;
  if (create) {
    const auto name = L"Global\\BShare.VirtualCamera.CredentialLock." + sid;
    creation_lock.handle = CreateMutexW(&attributes, FALSE, name.c_str());
    if (!creation_lock.handle) { LocalFree(security); return {}; }
    const auto waited = WaitForSingleObject(creation_lock.handle, 5000);
    creation_lock.held = waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED;
    if (!creation_lock.held) { LocalFree(security); return {}; }
  }
  HKEY key = nullptr;
  auto status = create ? RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\BShare\\VirtualCamera", 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_READ | KEY_WRITE | WRITE_DAC, &attributes, &key, nullptr) :
      RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\BShare\\VirtualCamera", 0, KEY_READ, &key);
  if (status != ERROR_SUCCESS) { LocalFree(security); return {}; }
  if (create) RegSetKeySecurity(key, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, security);
  LocalFree(security);
  wchar_t buffer[33]{}; DWORD bytes = sizeof(buffer), type = 0;
  status = RegQueryValueExW(key, L"Credential", nullptr, &type, reinterpret_cast<BYTE*>(buffer), &bytes);
  std::wstring value = status == ERROR_SUCCESS && type == REG_SZ && bytes <= sizeof(buffer) ? std::wstring(buffer, wcsnlen(buffer, 33)) : L"";
  if (!ValidCredential(value) && create) {
    // RtlGenRandom is the OS cryptographic RNG (advapi32 SystemFunction036).
    auto module = LoadLibraryW(L"advapi32.dll");
    using Random = BOOLEAN(WINAPI*)(void*, ULONG);
    auto random = module ? reinterpret_cast<Random>(GetProcAddress(module, "SystemFunction036")) : nullptr;
    uint8_t random_bytes[16]{};
    if (random && random(random_bytes, sizeof(random_bytes))) {
      static constexpr wchar_t hex[] = L"0123456789abcdef";
      value.clear();
      for (auto byte : random_bytes) { value += hex[byte >> 4]; value += hex[byte & 15]; }
      status = RegSetValueExW(key, L"Credential", 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), DWORD((value.size() + 1) * sizeof(wchar_t)));
      if (status != ERROR_SUCCESS) value.clear();
    } else value.clear();
    if (module) FreeLibrary(module);
  }
  RegCloseKey(key);
  return ValidCredential(value) ? value : L"";
}
inline std::wstring PipeName(const std::wstring& sid, const std::wstring& credential) {
  return PipeNameForSid(sid) + L"." + credential;
}

// Publish never waits for a consumer or performs pipe I/O. It retains only the
// newest frame. Four bounded workers allow independent FrameServer instances.
class FramePublisher final {
 public:
  // The explicit credential overload also permits isolated transport tests.
  explicit FramePublisher(const std::wstring& credential_override = {}) {
    const auto sid = CurrentUserSid();
    const auto credential = credential_override.empty() ? ProducerCredential() : credential_override;
    if (sid.empty() || !ValidCredential(credential)) return;
    pipe_name_ = PipeName(sid, credential);
    // User controls their own camera. FrameServer runs as SYSTEM/LOCAL SERVICE.
    const auto sddl = L"O:" + sid + L"D:P(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;" + sid + L")";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &security_, nullptr)) return;
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), security_, FALSE};
    // An unconnected owner pipe is a process-lifetime, cross-session lock. Its
    // handle closes automatically on crashes; unlike a semaphore it cannot be
    // left permanently taken by a dead producer.
    const auto owner_name = pipe_name_ + L".owner";
    owner_ = CreateNamedPipeW(owner_name.c_str(), PIPE_ACCESS_OUTBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 0, 0, 0, &attributes);
    if (owner_ == INVALID_HANDLE_VALUE) return;
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stop_event_) return;
    for (unsigned i = 0; i != 4; ++i) workers_.emplace_back([this] { Run(); });
  }
  ~FramePublisher() {
    stopped_.store(true);
    if (stop_event_) SetEvent(stop_event_);
    changed_.notify_all();
    for (auto& worker : workers_) if (worker.joinable()) worker.join();
    if (stop_event_) CloseHandle(stop_event_);
    if (owner_ != INVALID_HANDLE_VALUE) CloseHandle(owner_);
    if (security_) LocalFree(security_);
  }
  FramePublisher(const FramePublisher&) = delete;
  FramePublisher& operator=(const FramePublisher&) = delete;
  bool IsReady() const noexcept {
    return stop_event_ != nullptr && owner_ != INVALID_HANDLE_VALUE && !stopped_.load();
  }
  bool Publish(const uint8_t* bgra, uint32_t width, uint32_t height, uint32_t stride) {
    if (!bgra || !width || !height || width > 4096 || height > 4096 ||
        uint64_t(width) * height > kMaxPixels || stride < uint64_t(width) * 4 || stopped_ || !stop_event_) return false;
    std::unique_lock lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) return false;
    auto frame = std::make_shared<Frame>();
    frame->header.width = width;
    frame->header.height = height;
    frame->header.bytes = width * height * 4;
    frame->pixels.resize(frame->header.bytes);
    for (uint32_t y = 0; y < height; ++y)
      std::memcpy(frame->pixels.data() + size_t(y) * width * 4, bgra + size_t(y) * stride, width * 4);
    latest_ = std::move(frame);
    ++generation_;
    lock.unlock();
    changed_.notify_all();
    return true;
  }
  void Clear() {
    if (!stop_event_) return;
    { std::lock_guard lock(mutex_); latest_ = std::make_shared<Frame>(); ++generation_; }
    changed_.notify_all();
  }
 private:
  struct Frame { WireHeader header; std::vector<uint8_t> pixels; };
  bool Complete(HANDLE pipe, OVERLAPPED& operation, DWORD wait_ms) {
    const HANDLE events[] = { stop_event_, operation.hEvent };
    DWORD result = WaitForMultipleObjects(2, events, FALSE, wait_ms);
    if (result != WAIT_OBJECT_0 + 1) {
      CancelIoEx(pipe, &operation);
      // A canceled OVERLAPPED must complete before its stack storage is freed.
      WaitForSingleObject(operation.hEvent, INFINITE);
      return false;
    }
    DWORD bytes = 0;
    return GetOverlappedResult(pipe, &operation, &bytes, FALSE) != FALSE;
  }
  bool Write(HANDLE pipe, HANDLE event, const void* data, DWORD count) {
    OVERLAPPED operation{};
    operation.hEvent = event;
    ResetEvent(event);
    DWORD bytes = 0;
    if (WriteFile(pipe, data, count, &bytes, &operation)) return bytes == count;
    if (GetLastError() != ERROR_IO_PENDING || !Complete(pipe, operation, 250)) return false;
    return GetOverlappedResult(pipe, &operation, &bytes, FALSE) && bytes == count;
  }
  void Run() {
    SECURITY_ATTRIBUTES attributes{sizeof(attributes), security_, FALSE};
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!event) return;
    while (!stopped_) {
      HANDLE pipe = CreateNamedPipeW(pipe_name_.c_str(), PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
          PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
          4, 65536, 0, 0, &attributes);
      if (pipe == INVALID_HANDLE_VALUE) { WaitForSingleObject(stop_event_, 250); continue; }
      OVERLAPPED connection{};
      connection.hEvent = event;
      ResetEvent(event);
      BOOL connected = ConnectNamedPipe(pipe, &connection);
      DWORD error = connected ? ERROR_SUCCESS : GetLastError();
      bool ready = connected || error == ERROR_PIPE_CONNECTED;
      if (error == ERROR_IO_PENDING) ready = Complete(pipe, connection, INFINITE);
      uint64_t sent = ~uint64_t(0);
      while (ready && !stopped_) {
        std::shared_ptr<Frame> frame;
        {
          std::unique_lock lock(mutex_);
          changed_.wait_for(lock, std::chrono::milliseconds(250), [&] { return stopped_ || generation_ != sent; });
          if (stopped_) break;
          // Heartbeat the retained frame even when the encoder sends nothing
          // new (for example an unchanged phone screen).
          sent = generation_;
          frame = latest_;
        }
        if (!frame) frame = std::make_shared<Frame>();
        ready = Write(pipe, event, &frame->header, sizeof(WireHeader));
        if (ready && frame->header.bytes) ready = Write(pipe, event, frame->pixels.data(), frame->header.bytes);
      }
      CancelIoEx(pipe, nullptr);
      DisconnectNamedPipe(pipe);
      CloseHandle(pipe);
    }
    CloseHandle(event);
  }
  std::wstring pipe_name_;
  PSECURITY_DESCRIPTOR security_ = nullptr;
  HANDLE stop_event_ = nullptr;
  HANDLE owner_ = INVALID_HANDLE_VALUE;
  std::atomic_bool stopped_{false};
  std::mutex mutex_;
  std::condition_variable changed_;
  uint64_t generation_ = 0;
  std::shared_ptr<Frame> latest_;
  std::vector<std::thread> workers_;
};
} // namespace bshare::virtual_camera
