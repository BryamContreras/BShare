#include <memory>
#include <string>
#include "rtc_audio_device.h"
// Expose only this header's implementation handle to the isolated fixture. This
// lets headless CI inject COM endpoints without adding a product testing API.
#define private public
#include "third_party/flutter_webrtc/windows/windows_media_audio_router.h"
#undef private
#include "third_party/flutter_webrtc/windows/windows_media_audio_router.cc"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <iostream>

namespace {
class Audio : public libwebrtc::RTCAudioDevice {
 public:
  std::vector<std::string> ids;
  std::atomic<int> selection{-1};
  std::atomic<int> volume_writes{0};
  int16_t PlayoutDevices() override { return static_cast<int16_t>(ids.size()); }
  int16_t RecordingDevices() override { return 0; }
  int32_t PlayoutDeviceName(uint16_t index, char* name, char* guid) override {
    if (index >= ids.size()) return -1;
    std::snprintf(name, kAdmMaxDeviceNameSize, "Output %u", index);
    std::snprintf(guid, kAdmMaxGuidSize, "%s", ids[index].c_str());
    return 0;
  }
  int32_t RecordingDeviceName(uint16_t, char*, char*) override { return -1; }
  int32_t SetPlayoutDevice(uint16_t index) override { selection = index; return 0; }
  int32_t SetRecordingDevice(uint16_t) override { assert(false); return -1; }
  int32_t OnDeviceChange(OnDeviceChangeCallback) override { return 0; }
  int32_t SetMicrophoneVolume(uint32_t) override { ++volume_writes; return -1; }
  int32_t MicrophoneVolume(uint32_t& value) override { value = 0; return 0; }
  int32_t SetSpeakerVolume(uint32_t) override { ++volume_writes; return -1; }
  int32_t SpeakerVolume(uint32_t& value) override { value = 0; return 0; }
};

// CI workers need no sound card. These COM doubles still exercise the actual
// routing implementation, including endpoint identity and the first-peer reset.
class Endpoint final : public IMMDevice {
 public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override { return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE Activate(REFIID, DWORD, PROPVARIANT*, void**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE OpenPropertyStore(DWORD, IPropertyStore**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetId(LPWSTR* id) override {
    constexpr wchar_t value[] = L"actual-media-output";
    *id = static_cast<LPWSTR>(CoTaskMemAlloc(sizeof(value)));
    if (!*id) return E_OUTOFMEMORY;
    std::memcpy(*id, value, sizeof(value));
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetState(DWORD* state) override { *state = DEVICE_STATE_ACTIVE; return S_OK; }
};

class Endpoints final : public IMMDeviceEnumerator {
 public:
  Endpoint endpoint;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override { return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE EnumAudioEndpoints(EDataFlow, DWORD, IMMDeviceCollection**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetDefaultAudioEndpoint(EDataFlow flow, ERole role, IMMDevice** value) override {
    assert(flow == eRender && role == eMultimedia);
    *value = &endpoint;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDevice(LPCWSTR, IMMDevice**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE RegisterEndpointNotificationCallback(IMMNotificationClient*) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE UnregisterEndpointNotificationCallback(IMMNotificationClient*) override { return S_OK; }
};
}

int main() {
  using namespace flutter_webrtc_plugin;
  assert(FindMediaAudioOutputIndex("{0.0}.{ABC}", {"virtual", "{0.0}.{abc}"}) == 1);
  assert(!FindMediaAudioOutputIndex("missing", {"unrelated-virtual-device"}));
  assert(!FindMediaAudioOutputIndex("", {""}));
  {
    Endpoints endpoints;
    libwebrtc::scoped_refptr<Audio> audio = new libwebrtc::RefCountedObject<Audio>();
    audio->ids = {"unrelated-virtual-output", "ACTUAL-MEDIA-OUTPUT"};
    WindowsMediaAudioRouter::Impl routing(nullptr);  // No background COM worker.
    routing.audio = audio;
    routing.Route(&endpoints);
    assert(audio->selection == 1);
    audio->selection = -1;  // Lazy media-engine Init resets the selected output.
    routing.signals->force_route = true;
    routing.Route(&endpoints, true);
    assert(audio->selection == 1);
    routing.SelectExplicit("unrelated-virtual-output");
    audio->selection = 0;
    routing.signals->force_route = true;
    routing.Route(&endpoints);
    assert(audio->selection == 0);  // OS default changes retain explicit output.
    audio->selection = -1;
    routing.Route(&endpoints, true);
    assert(audio->selection == 0);  // First peer restores explicit output too.
    assert(audio->volume_writes == 0);
    routing.signals->explicit_selection = false;
    routing.signals->force_route = true;
    audio->ids = {"unrelated-virtual-output"};
    audio->selection = -1;
    routing.Route(&endpoints);
    assert(audio->selection == -1);  // Never substitute an unrelated output.
  }
  {
    auto signals = std::make_shared<RoutingSignals>();
    signals->explicit_selection = true;
    signals->explicit_id = "selected-output";
    auto* notifications = new DeviceNotifications(signals);
    notifications->OnDefaultDeviceChanged(eCapture, eCommunications, L"ignored");
    assert(WaitForSingleObject(signals->update, 0) == WAIT_TIMEOUT);
    notifications->OnDefaultDeviceChanged(eRender, eCommunications, L"ignored");
    assert(WaitForSingleObject(signals->update, 0) == WAIT_TIMEOUT);
    notifications->OnDefaultDeviceChanged(eRender, eMultimedia, L"new-default");
    assert(WaitForSingleObject(signals->update, 0) == WAIT_OBJECT_0);
    assert(signals->explicit_selection);  // Keep the user's explicit output.
    notifications->OnDeviceRemoved(L"another-output");
    assert(signals->explicit_selection);
    notifications->OnDeviceRemoved(L"SELECTED-OUTPUT");
    assert(!signals->explicit_selection && signals->force_route);
    notifications->Release();
  }
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  assert(SUCCEEDED(com));
  {
    Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
    assert(SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator))));
    Microsoft::WRL::ComPtr<IMMDevice> endpoint;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &endpoint))) {
      LPWSTR id = nullptr;
      assert(SUCCEEDED(endpoint->GetId(&id)));
      const std::string expected = Utf8(id);
      CoTaskMemFree(id);
      libwebrtc::scoped_refptr<Audio> audio = new libwebrtc::RefCountedObject<Audio>();
      audio->ids = {"unrelated-virtual-output", expected};
      {
        WindowsMediaAudioRouter router(audio);
        assert(audio->selection == 1);
        assert(audio->volume_writes == 0);
        // The SDK lazily resets its ADM to communications on the first peer.
        // Reusing the same multimedia ID must not skip this required routing.
        audio->selection = -1;
        router.PrepareFirstPeerAfterMediaEngineInitialization();
        assert(audio->selection == 1);
        router.RespectExplicitOutputSelection("unrelated-virtual-output");
        audio->selection = -1;
        router.PrepareFirstPeerAfterMediaEngineInitialization();
        assert(audio->selection == 0);  // Reapply the user's explicit output.
      }
      libwebrtc::scoped_refptr<Audio> missing = new libwebrtc::RefCountedObject<Audio>();
      missing->ids = {"unrelated-virtual-output"};
      { WindowsMediaAudioRouter router(missing); }
      assert(missing->selection == -1);
      assert(missing->volume_writes == 0);
      std::cout << "Real OS multimedia ID selected by exact SDK ID; no capture/volume writes.\n";
    } else {
      std::cout << "No multimedia output; ID and explicit-selection policy passed.\n";
    }
    { WindowsMediaAudioRouter router(nullptr); }
  }
  CoUninitialize();
}
