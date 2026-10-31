#include "windows_media_audio_router.h"
#include "media_audio_routing_policy.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {
namespace {
using Microsoft::WRL::ComPtr;
std::string Utf8(const wchar_t* text) {
  if (!text) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string value(static_cast<size_t>(size), '\0');
  if (!WideCharToMultiByte(CP_UTF8, 0, text, -1, value.data(), size, nullptr, nullptr)) return {};
  value.pop_back();
  return value;
}
struct RoutingSignals {
  HANDLE stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE update = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  HANDLE initial = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE prepared = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::mutex selection_mutex;
  bool explicit_selection = false;
  bool force_route = true;
  bool prepare_peer = false;
  std::string explicit_id;
  std::string automatic_id;
  ~RoutingSignals() {
    if (stop) CloseHandle(stop);
    if (update) CloseHandle(update);
    if (initial) CloseHandle(initial);
    if (prepared) CloseHandle(prepared);
  }
  void Update() { if (update) SetEvent(update); }
  void Removed(const wchar_t* id) {
    {
      std::lock_guard<std::mutex> lock(selection_mutex);
      if (explicit_selection && SameAudioEndpointId(explicit_id, Utf8(id))) {
        explicit_selection = false;
        explicit_id.clear();
        force_route = true;
      }
      if (SameAudioEndpointId(automatic_id, Utf8(id))) force_route = true;
    }
    Update();
  }
};

// COM callbacks only signal the owned worker. They never call WebRTC, enumerate
// devices, or change another application's state on an audio service thread.
class DeviceNotifications final : public IMMNotificationClient {
 public:
  explicit DeviceNotifications(std::shared_ptr<RoutingSignals> signals)
      : signals_(std::move(signals)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (iid == IID_IUnknown || iid == __uuidof(IMMNotificationClient)) {
      *value = static_cast<IMMNotificationClient*>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --references_; if (!count) delete this; return count;
  }
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
    if (flow == eRender && (role == eMultimedia || role == eConsole)) signals_->Update();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { signals_->Update(); return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR id) override { signals_->Removed(id); return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR id, DWORD state) override {
    if (!(state & DEVICE_STATE_ACTIVE)) signals_->Removed(id); else signals_->Update();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
 private:
  std::atomic<ULONG> references_{1};
  std::shared_ptr<RoutingSignals> signals_;
};
}  // namespace

struct WindowsMediaAudioRouter::Impl {
  explicit Impl(libwebrtc::scoped_refptr<libwebrtc::RTCAudioDevice> audio_device)
      : audio(std::move(audio_device)), signals(std::make_shared<RoutingSignals>()) {
    if (!audio || !signals->stop || !signals->update || !signals->initial || !signals->prepared) return;
    worker = std::thread([this] { Run(); });
    // Initial routing is queued before any peer can start its render stream.
    // A failed or absent audio endpoint must never block video-only startup.
    WaitForSingleObject(signals->initial, 1000);
  }
  ~Impl() {
    if (signals->stop) SetEvent(signals->stop);
    if (worker.joinable()) worker.join();
  }
  void SelectExplicit(const std::string& id) {
    std::lock_guard<std::mutex> lock(signals->selection_mutex);
    signals->explicit_selection = true;
    signals->explicit_id = id;
  }
  void PreparePeer() {
    if (!worker.joinable()) return;
    {
      std::lock_guard<std::mutex> lock(signals->selection_mutex);
      signals->force_route = true;
      signals->prepare_peer = true;
      ResetEvent(signals->prepared);
    }
    signals->Update();
    WaitForSingleObject(signals->prepared, 2000);
  }
  void Route(IMMDeviceEnumerator* enumerator, bool prepare_peer = false) {
    bool explicit_selection = false;
    std::string id;
    {
      std::lock_guard<std::mutex> lock(signals->selection_mutex);
      explicit_selection = signals->explicit_selection;
      if (explicit_selection && !prepare_peer) return;
      if (explicit_selection) id = signals->explicit_id;
    }
    if (!explicit_selection) {
      ComPtr<IMMDevice> endpoint;
      // The communications role is intentionally never used here.
      if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &endpoint))) return;
      LPWSTR raw_id = nullptr;
      if (FAILED(endpoint->GetId(&raw_id))) return;
      id = Utf8(raw_id);
      CoTaskMemFree(raw_id);
    }
    if (id.empty()) return;
    {
      std::lock_guard<std::mutex> lock(signals->selection_mutex);
      if (!signals->force_route && SameAudioEndpointId(id, routed_id)) return;
    }
    const int16_t count = audio->PlayoutDevices();
    std::vector<std::string> ids;
    for (int i = 0; i < count; ++i) {
      char name[libwebrtc::RTCAudioDevice::kAdmMaxDeviceNameSize + 1]{};
      char guid[libwebrtc::RTCAudioDevice::kAdmMaxGuidSize + 1]{};
      const auto index = static_cast<uint16_t>(i);
      if (audio->PlayoutDeviceName(index, name, guid) == 0) ids.emplace_back(guid);
      else ids.emplace_back();
    }
    const auto index = FindMediaAudioOutputIndex(id, ids);
    if (!index) return;
    {
      std::lock_guard<std::mutex> lock(signals->selection_mutex);
      if (signals->explicit_selection != explicit_selection ||
          (explicit_selection && !SameAudioEndpointId(signals->explicit_id, id))) return;
      if (audio->SetPlayoutDevice(static_cast<uint16_t>(*index)) == 0) {
        routed_id = id;
        if (!explicit_selection) signals->automatic_id = id;
        signals->force_route = false;
      }
    }
    if (prepare_peer) {
      // SetPlayoutDevice posts to the SDK worker. Its name query is a blocking
      // worker call, so this fence completes after the selection was applied.
      char name[libwebrtc::RTCAudioDevice::kAdmMaxDeviceNameSize + 1]{};
      char guid[libwebrtc::RTCAudioDevice::kAdmMaxGuidSize + 1]{};
      audio->PlayoutDeviceName(static_cast<uint16_t>(*index), name, guid);
    }
  }
  void Run() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com)) { SetEvent(signals->initial); return; }
    {
      ComPtr<IMMDeviceEnumerator> enumerator;
      if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
          CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator)))) {
        ComPtr<IMMNotificationClient> notifications;
        notifications.Attach(new DeviceNotifications(signals));
        const bool subscribed = SUCCEEDED(enumerator->RegisterEndpointNotificationCallback(notifications.Get()));
        Route(enumerator.Get());
        SetEvent(signals->initial);
        const HANDLE events[]{signals->stop, signals->update};
        while (WaitForMultipleObjects(2, events, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
          bool prepare = false;
          {
            std::lock_guard<std::mutex> lock(signals->selection_mutex);
            prepare = signals->prepare_peer;
            signals->prepare_peer = false;
          }
          Route(enumerator.Get(), prepare);
          if (prepare) SetEvent(signals->prepared);
        }
        if (subscribed) enumerator->UnregisterEndpointNotificationCallback(notifications.Get());
      } else SetEvent(signals->initial);
    }
    CoUninitialize();
  }
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioDevice> audio;
  std::shared_ptr<RoutingSignals> signals;
  std::thread worker;
  std::string routed_id;
};

WindowsMediaAudioRouter::WindowsMediaAudioRouter(
    libwebrtc::scoped_refptr<libwebrtc::RTCAudioDevice> audio_device)
    : impl_(std::make_unique<Impl>(std::move(audio_device))) {}
WindowsMediaAudioRouter::~WindowsMediaAudioRouter() = default;
void WindowsMediaAudioRouter::RespectExplicitOutputSelection(const std::string& id) {
  impl_->SelectExplicit(id);
}
void WindowsMediaAudioRouter::PrepareFirstPeerAfterMediaEngineInitialization() {
  impl_->PreparePeer();
}
}  // namespace flutter_webrtc_plugin
