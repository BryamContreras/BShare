// Optional local diagnostic: silent media output + duck notifications. No input
// device, audio recording, endpoint volume, or global communications settings.
#include <windows.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <string>

using Microsoft::WRL::ComPtr;
struct Renderer {
  ComPtr<IMMDevice> endpoint;
  ComPtr<IAudioClient> audio;
  ComPtr<IAudioRenderClient> render;
  HANDLE event = nullptr;
  UINT32 capacity = 0;
  bool started = false;
  ~Renderer() { if (started) audio->Stop(); if (event) CloseHandle(event); }
  HRESULT Open(ERole role, AUDIO_STREAM_CATEGORY category,
               bool set_properties = true, bool explicit_device = false,
               bool default_session = false) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) return hr;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, role, &endpoint);
    if (FAILED(hr)) return hr;
    if (explicit_device) {
      LPWSTR wanted = nullptr;
      hr = endpoint->GetId(&wanted);
      if (FAILED(hr)) return hr;
      ComPtr<IMMDeviceCollection> devices;
      hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &devices);
      endpoint.Reset();
      if (SUCCEEDED(hr)) {
        UINT count = 0; devices->GetCount(&count);
        for (UINT i = 0; i < count && !endpoint; ++i) {
          ComPtr<IMMDevice> candidate; devices->Item(i, &candidate);
          LPWSTR id = nullptr;
          if (candidate && SUCCEEDED(candidate->GetId(&id))) {
            if (_wcsicmp(id, wanted) == 0) endpoint = candidate;
            CoTaskMemFree(id);
          }
        }
      }
      CoTaskMemFree(wanted);
      if (!endpoint) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }
    hr = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_INPROC_SERVER, nullptr,
      reinterpret_cast<void**>(audio.GetAddressOf()));
    if (FAILED(hr)) return hr;
    ComPtr<IAudioClient2> client2;
    if (set_properties && SUCCEEDED(audio.As(&client2))) {
      AudioClientProperties properties{};
      properties.cbSize = sizeof(properties);
      properties.eCategory = category;
      hr = client2->SetClientProperties(&properties);
      if (FAILED(hr)) return hr;
    }
    WAVEFORMATEX* wave = nullptr;
    hr = audio->GetMixFormat(&wave);
    if (FAILED(hr)) return hr;
    GUID session{}; CoCreateGuid(&session);
    hr = audio->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      0, 0, wave, default_session ? nullptr : &session);
    CoTaskMemFree(wave);
    if (FAILED(hr)) return hr;
    event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event) return HRESULT_FROM_WIN32(GetLastError());
    if (FAILED(hr = audio->SetEventHandle(event))) return hr;
    if (FAILED(hr = audio->GetBufferSize(&capacity))) return hr;
    return audio->GetService(IID_PPV_ARGS(&render));
  }
  HRESULT Pump() {
    UINT32 padding = 0;
    HRESULT hr = audio->GetCurrentPadding(&padding);
    if (FAILED(hr)) return hr;
    const UINT32 count = capacity - padding;
    if (!count) return S_OK;
    BYTE* data = nullptr;
    hr = render->GetBuffer(count, &data);
    if (FAILED(hr)) return hr;
    return render->ReleaseBuffer(count, AUDCLNT_BUFFERFLAGS_SILENT);
  }
  HRESULT Start() { HRESULT hr = Pump(); if (FAILED(hr)) return hr;
    hr = audio->Start(); started = SUCCEEDED(hr); return hr; }
};
class DuckNotifications final : public IAudioVolumeDuckNotification {
 public:
  std::atomic<ULONG> references{1};
  std::atomic<unsigned> ducks{0}, unducks{0}, maximum{0};
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override {
    if (!value) return E_POINTER; *value = nullptr;
    if (iid == IID_IUnknown || iid == __uuidof(IAudioVolumeDuckNotification)) {
      *value = static_cast<IAudioVolumeDuckNotification*>(this); AddRef(); return S_OK;
    } return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
  ULONG STDMETHODCALLTYPE Release() override { ULONG left = --references; if (!left) delete this; return left; }
  HRESULT STDMETHODCALLTYPE OnVolumeDuckNotification(LPCWSTR, UINT32 count) override {
    ++ducks; unsigned previous = maximum.load();
    while (previous < count && !maximum.compare_exchange_weak(previous, count)) {}
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnVolumeUnduckNotification(LPCWSTR) override { ++unducks; return S_OK; }
};
int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "";
  if (mode == "--communications-only" || mode == "--legacy-comms" ||
      mode == "--legacy-explicit" || mode == "--legacy-cached" ||
      mode == "--explicit-communication") {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialized)) return 3;
    int exit_code = 0;
    {
      Renderer communication;
      ComPtr<ISimpleAudioVolume> cached_volume;
      if (mode == "--legacy-cached") {
        ComPtr<IMMDeviceEnumerator> enumerator;
        ComPtr<IMMDevice> endpoint;
        ComPtr<IAudioSessionManager> manager;
        if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&enumerator))) &&
            SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eCommunications, &endpoint)) &&
            SUCCEEDED(endpoint->Activate(__uuidof(IAudioSessionManager), CLSCTX_INPROC_SERVER,
              nullptr, reinterpret_cast<void**>(manager.GetAddressOf()))))
          manager->GetSimpleAudioVolume(nullptr, FALSE, &cached_volume);
      }
      const bool legacy = mode.rfind("--legacy-", 0) == 0;
      const bool explicit_device = mode != "--legacy-comms" && mode != "--communications-only";
      HRESULT opened = communication.Open(explicit_device ? eMultimedia : eCommunications,
          legacy ? AudioCategory_Other : AudioCategory_Communications,
          !legacy, explicit_device, legacy);
      if (SUCCEEDED(opened) && argc > 2 && std::string(argv[2]) == "--session-opt-out") {
        ComPtr<IAudioSessionControl> basic;
        ComPtr<IAudioSessionControl2> session;
        opened = communication.audio->GetService(IID_PPV_ARGS(&basic));
        if (SUCCEEDED(opened)) opened = basic.As(&session);
        if (SUCCEEDED(opened)) opened = session->SetDuckingPreference(TRUE);
      }
      if (SUCCEEDED(opened)) opened = communication.Start();
      const auto until = GetTickCount64() + 2000;
      while (SUCCEEDED(opened) && GetTickCount64() < until) {
        WaitForSingleObject(communication.event, 20);
        opened = communication.Pump();
      }
      if (FAILED(opened)) exit_code = 1;
    }
    CoUninitialize();
    return exit_code;
  }
  const int seconds = argc > 1 ? std::atoi(argv[1]) : 30;
  const bool optout_test = argc > 2 && std::string(argv[2]) == "--self-test-optout";
  const std::string calibration = argc > 2 ? argv[2] : "";
  const bool self_test = calibration.rfind("--self-test", 0) == 0;
  if (seconds < 5 || seconds > 120) return 2;
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(com)) return 3;
  int result = 0;
  {
    Renderer media;
    HRESULT hr = media.Open(eMultimedia, AudioCategory_Media);
    ComPtr<IAudioSessionControl2> session;
    ComPtr<IAudioSessionManager2> manager;
    ComPtr<DuckNotifications> callback;
    callback.Attach(new DuckNotifications());
    LPWSTR session_id = nullptr;
    bool subscribed = false;
    ComPtr<IAudioSessionControl> basic_session;
    if (SUCCEEDED(hr)) hr = media.audio->GetService(IID_PPV_ARGS(&basic_session));
    if (SUCCEEDED(hr)) hr = basic_session.As(&session);
    if (SUCCEEDED(hr)) hr = media.endpoint->Activate(__uuidof(IAudioSessionManager2),
      CLSCTX_INPROC_SERVER, nullptr, reinterpret_cast<void**>(manager.GetAddressOf()));
    if (SUCCEEDED(hr)) hr = session->GetSessionInstanceIdentifier(&session_id);
    if (SUCCEEDED(hr)) { hr = manager->RegisterDuckNotification(session_id, callback.Get()); subscribed = SUCCEEDED(hr); }
    if (SUCCEEDED(hr)) hr = media.Start();
    if (SUCCEEDED(hr)) {
      std::cout << "{\"ready\":true,\"pid\":" << GetCurrentProcessId()
        << ",\"category\":\"Media\",\"silent\":true,\"inputOpened\":false}" << std::endl;
      const ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(seconds) * 1000;
      while (GetTickCount64() < deadline) {
        WaitForSingleObject(media.event, 50); hr = media.Pump(); if (FAILED(hr)) break;
        if (self_test && GetTickCount64() + static_cast<ULONGLONG>(seconds - 2) * 1000 >= deadline) {
          wchar_t executable[32768]{};
          GetModuleFileNameW(nullptr, executable, 32768);
          std::wstring command = L"\"" + std::wstring(executable) + L"\" --communications-only";
          if (optout_test) command += L" --session-opt-out";
          if (calibration == "--self-test-legacy-comms") command = L"\"" + std::wstring(executable) + L"\" --legacy-comms";
          if (calibration == "--self-test-legacy-explicit") command = L"\"" + std::wstring(executable) + L"\" --legacy-explicit";
          if (calibration == "--self-test-legacy-cached") command = L"\"" + std::wstring(executable) + L"\" --legacy-cached";
          if (calibration == "--self-test-explicit-communication") command = L"\"" + std::wstring(executable) + L"\" --explicit-communication";
          STARTUPINFOW startup{}; startup.cb = sizeof(startup);
          startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
          PROCESS_INFORMATION child{};
          if (!CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
              CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) {
            hr = HRESULT_FROM_WIN32(GetLastError());
          } else {
            const auto until = GetTickCount64() + 5000;
            while (WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT && GetTickCount64() < until) {
              WaitForSingleObject(media.event, 20); media.Pump();
            }
            DWORD child_exit = 1;
            GetExitCodeProcess(child.hProcess, &child_exit);
            if (child_exit != 0) hr = E_FAIL;
            CloseHandle(child.hThread); CloseHandle(child.hProcess);
          }
          // Only one calibration communication stream per optional self-test.
          break;
        }
      }
      if (self_test) { const auto until = GetTickCount64() + 1500;
        while (GetTickCount64() < until) { WaitForSingleObject(media.event, 50); media.Pump(); } }
    }
    if (subscribed) manager->UnregisterDuckNotification(callback.Get());
    CoTaskMemFree(session_id);
    if (FAILED(hr)) { std::cerr << "Probe failed: 0x" << std::hex << static_cast<unsigned>(hr) << std::endl; result = 1; }
    std::cout << "{\"completed\":true,\"duckNotifications\":" << callback->ducks.load()
      << ",\"unduckNotifications\":" << callback->unducks.load()
      << ",\"maxCommunicationSessions\":" << callback->maximum.load()
      << ",\"selfTest\":" << (self_test ? "true" : "false")
      << ",\"communicationSessionOptOut\":" << (optout_test ? "true" : "false")
      << ",\"calibration\":\"" << calibration << "\""
      << ",\"mediaSaved\":false,\"globalSettingsChanged\":false,\"exitCode\":" << result << "}" << std::endl;
  }
  CoUninitialize();
  return result;
}
