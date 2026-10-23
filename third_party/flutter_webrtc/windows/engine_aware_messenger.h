// BShare modification: keep plugin cleanup safe after Flutter invalidates its
// Windows engine messenger, while retaining normal live-channel unregisters.
#ifndef FLUTTER_WEBRTC_ENGINE_AWARE_MESSENGER_H_
#define FLUTTER_WEBRTC_ENGINE_AWARE_MESSENGER_H_

#include <flutter/binary_messenger.h>
#include <flutter_messenger.h>

#include <thread>
#include <utility>

namespace flutter_webrtc_plugin {

class EngineAwareMessenger final : public flutter::BinaryMessenger {
 public:
  EngineAwareMessenger(flutter::BinaryMessenger* delegate,
                       FlutterDesktopMessengerRef core)
      : delegate_(delegate),
        core_(FlutterDesktopMessengerAddRef(core)),
        platform_thread_(std::this_thread::get_id()) {}

  ~EngineAwareMessenger() override {
    FlutterDesktopMessengerRelease(core_);
  }

  EngineAwareMessenger(const EngineAwareMessenger&) = delete;
  EngineAwareMessenger& operator=(const EngineAwareMessenger&) = delete;

  void Send(const std::string& channel,
            const uint8_t* message,
            size_t message_size,
            flutter::BinaryReply reply = nullptr) const override {
    ScopedLock lock(core_, platform_thread_);
    if (FlutterDesktopMessengerIsAvailable(core_)) {
      delegate_->Send(channel, message, message_size, std::move(reply));
    }
  }

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {
    ScopedLock lock(core_, platform_thread_);
    // Flutter invalidates the core messenger before destroying registrars.
    // Its Windows SetCallback API still dereferences the engine in release.
    // The dispatcher and delegate's handler map are already being destroyed
    // then; ordinary live-engine disposal must continue to remove its handler.
    if (FlutterDesktopMessengerIsAvailable(core_)) {
      delegate_->SetMessageHandler(channel, std::move(handler));
    }
  }

 private:
  class ScopedLock {
   public:
    ScopedLock(FlutterDesktopMessengerRef core,
               std::thread::id platform_thread)
        : core_(core), locked_(std::this_thread::get_id() != platform_thread) {
      if (locked_) {
        FlutterDesktopMessengerLock(core_);
      }
    }
    ~ScopedLock() {
      if (locked_) {
        FlutterDesktopMessengerUnlock(core_);
      }
    }

   private:
    FlutterDesktopMessengerRef core_;
    bool locked_;
  };

  flutter::BinaryMessenger* delegate_;
  FlutterDesktopMessengerRef core_;
  std::thread::id platform_thread_;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_ENGINE_AWARE_MESSENGER_H_
