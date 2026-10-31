#ifndef BSHARE_DESKTOP_MEDIA_MANAGER_H_
#define BSHARE_DESKTOP_MEDIA_MANAGER_H_
#include "flutter_common.h"
#include <memory>

namespace flutter_webrtc_plugin {
class FlutterWebRTCBase;
class DesktopMediaManager {
 public:
  explicit DesktopMediaManager(FlutterWebRTCBase* base, TaskRunner* task_runner);
  ~DesktopMediaManager();
  void GetDirectories(std::unique_ptr<MethodResultProxy> result);
  void TakePhoto(const EncodableMap& arguments, std::unique_ptr<MethodResultProxy> result);
  void StartRecording(const EncodableMap& arguments, std::unique_ptr<MethodResultProxy> result);
  void StopRecording(const EncodableMap& arguments, std::unique_ptr<MethodResultProxy> result);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace flutter_webrtc_plugin
#endif
