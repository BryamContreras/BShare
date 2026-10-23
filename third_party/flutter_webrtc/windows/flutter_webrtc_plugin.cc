// BShare modification: guard messenger access after engine shutdown and keep
// WebRTC's task runner/messenger alive until its native channels are destroyed.
#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"

#include "flutter_common.h"
#include "flutter_webrtc.h"
#include "engine_aware_messenger.h"
#include "task_runner_windows.h"

#include <flutter/plugin_registrar_windows.h>

const char* kChannelName = "FlutterWebRTC.Method";
static flutter_webrtc_plugin::FlutterWebRTC* g_shared_instance = nullptr;

namespace flutter_webrtc_plugin {

// A webrtc plugin for windows/linux.
class FlutterWebRTCPluginImpl : public FlutterWebRTCPlugin {
 public:
  static void RegisterWithRegistrar(PluginRegistrar* registrar,
                                    FlutterDesktopMessengerRef core_messenger) {
    // Uses new instead of make_unique due to private constructor.
    std::unique_ptr<FlutterWebRTCPluginImpl> plugin(
        new FlutterWebRTCPluginImpl(registrar, core_messenger));
    plugin->channel_->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  virtual ~FlutterWebRTCPluginImpl() {
    channel_->SetMethodCallHandler(nullptr);
    if (g_shared_instance == webrtc_.get()) {
      g_shared_instance = nullptr;
    }
  }

  BinaryMessenger* messenger() { return messenger_.get(); }

  TextureRegistrar* textures() { return textures_; }

  TaskRunner* task_runner() { return task_runner_.get(); }

 private:
  // Creates a plugin that communicates on the given channel.
  FlutterWebRTCPluginImpl(PluginRegistrar* registrar,
                          FlutterDesktopMessengerRef core_messenger)
      : messenger_(std::make_unique<EngineAwareMessenger>(
            registrar->messenger(), core_messenger)),
        channel_(std::make_unique<MethodChannel>(
            messenger_.get(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())),
        textures_(registrar->texture_registrar()),
        task_runner_(std::make_unique<TaskRunnerWindows>()) {
    webrtc_ = std::make_unique<FlutterWebRTC>(this);
    g_shared_instance = webrtc_.get();
  }

  // Called when a method is called on |channel_|;
  void HandleMethodCall(const MethodCall& method_call,
                        std::unique_ptr<MethodResult> result) {
    // handle method call and forward to webrtc native sdk.
    auto method_call_proxy = MethodCallProxy::Create(method_call);
    webrtc_->HandleMethodCall(*method_call_proxy.get(),
                              MethodResultProxy::Create(std::move(result)));
  }

 private:
  // Reverse member destruction keeps WebRTC callbacks' task runner and
  // messenger alive until all WebRTC-owned channels and observers are gone.
  std::unique_ptr<EngineAwareMessenger> messenger_;
  std::unique_ptr<MethodChannel> channel_;
  TextureRegistrar* textures_;
  std::unique_ptr<TaskRunner> task_runner_;
  std::unique_ptr<FlutterWebRTC> webrtc_;
};

}  // namespace flutter_webrtc_plugin


void FlutterWebRTCPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_webrtc_plugin::FlutterWebRTCPluginImpl::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar),
      FlutterDesktopPluginRegistrarGetMessenger(registrar));
}

flutter_webrtc_plugin::FlutterWebRTC* FlutterWebRTCPluginSharedInstance() {
  return g_shared_instance;
}
