#ifndef FLUTTER_WEBRTC_WINDOWS_MEDIA_AUDIO_ROUTER_H_
#define FLUTTER_WEBRTC_WINDOWS_MEDIA_AUDIO_ROUTER_H_

#include <memory>
#include <string>
#include "rtc_audio_device.h"

namespace flutter_webrtc_plugin {

// WebRTC's Windows ADM defaults to the communications endpoint. A BShare
// receiver plays media, so choose the actual OS multimedia device by SDK ID.
// This never changes an endpoint's role, volume, or other applications' sessions.
class WindowsMediaAudioRouter final {
 public:
  explicit WindowsMediaAudioRouter(
      libwebrtc::scoped_refptr<libwebrtc::RTCAudioDevice> audio_device);
  ~WindowsMediaAudioRouter();
  void RespectExplicitOutputSelection(const std::string& device_id);
  void PrepareFirstPeerAfterMediaEngineInitialization();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace flutter_webrtc_plugin
#endif
