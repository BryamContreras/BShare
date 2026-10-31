#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksproxy.h>
#include <wrl/client.h>
#include <VersionHelpers.h>
#include <iostream>
#include <iomanip>
#include <string>
#include <vector>
#include <functional>
#include "VirtualCameraMediaSource.h"
#include "bshare_frame_publisher.h"
using Microsoft::WRL::ComPtr;
static constexpr wchar_t kRegistryPath[] = L"Software\\Classes\\CLSID\\{49CF4567-7334-49DD-9CEE-776E82374C91}\\InprocServer32";
static bool Supported() {
  // An emulated x64 helper on ARM64 cannot install a source DLL into the native
  // ARM64 FrameServer host. The app remains usable, this component is x64-only.
  using MachineQuery = BOOL(WINAPI*)(HANDLE, USHORT*, USHORT*);
  auto query = reinterpret_cast<MachineQuery>(GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2"));
  USHORT process_machine = 0, native_machine = 0;
  if (!query || !query(GetCurrentProcess(), &process_machine, &native_machine) || native_machine != IMAGE_FILE_MACHINE_AMD64) return false;
  auto module = LoadLibraryW(L"mfsensorgroup.dll");
  if (!module) return false;
  bool result = GetProcAddress(module, "MFCreateVirtualCamera") != nullptr;
  FreeLibrary(module);
  return result;
}
static void Error(HRESULT hr) {
  std::cerr << "BShare camera failed: 0x" << std::hex << std::uppercase << uint32_t(hr) << '\n';
}
static HRESULT RegisterSource(bool machine, const std::wstring& dll) {
  HKEY key = nullptr;
  LSTATUS result = RegCreateKeyExW(machine ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER,
      kRegistryPath, 0, nullptr, 0, KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr);
  if (result != ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
  result = RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE*>(dll.c_str()), DWORD((dll.size() + 1) * sizeof(wchar_t)));
  if (result == ERROR_SUCCESS) {
    const wchar_t threading[] = L"Both";
    result = RegSetValueExW(key, L"ThreadingModel", 0, REG_SZ, reinterpret_cast<const BYTE*>(threading), sizeof(threading));
  }
  RegCloseKey(key);
  return HRESULT_FROM_WIN32(result);
}
static bool SourceRegistered() {
  wchar_t path[32768]{}; DWORD size = sizeof(path), type = 0;
  if (RegGetValueW(HKEY_LOCAL_MACHINE, kRegistryPath, nullptr, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
      &type, path, &size) != ERROR_SUCCESS) return false;
  return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}
static HRESULT UnregisterSource(const std::wstring& expected) {
  wchar_t path[32768]{}; DWORD size = sizeof(path), type = 0;
  auto status = RegGetValueW(HKEY_LOCAL_MACHINE, kRegistryPath, nullptr, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
      &type, path, &size);
  if (status == ERROR_FILE_NOT_FOUND) return S_OK;
  if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);
  if (_wcsicmp(path, expected.c_str()) != 0) return S_FALSE; // belongs to another installed version
  status = RegDeleteTreeW(HKEY_LOCAL_MACHINE, L"Software\\Classes\\CLSID\\{49CF4567-7334-49DD-9CEE-776E82374C91}");
  return HRESULT_FROM_WIN32(status);
}
static HRESULT Camera(ComPtr<IMFVirtualCamera>& camera) {
  using Create = decltype(&MFCreateVirtualCamera);
  // Keep the module loaded for the returned COM object's full lifetime. This
  // helper is short lived; Windows releases the loader reference at process exit.
  static HMODULE module = LoadLibraryW(L"mfsensorgroup.dll");
  if (!module) return HRESULT_FROM_WIN32(ERROR_OLD_WIN_VERSION);
  auto create = reinterpret_cast<Create>(GetProcAddress(module, "MFCreateVirtualCamera"));
  HRESULT result = create ? create(MFVirtualCameraType_SoftwareCameraSource, MFVirtualCameraLifetime_System,
      MFVirtualCameraAccess_CurrentUser, VIRTUALCAMERAMEDIASOURCE_FRIENDLYNAME,
      VIRTUALCAMERAMEDIASOURCE_CLSID, nullptr, 0, &camera) : HRESULT_FROM_WIN32(ERROR_OLD_WIN_VERSION);
  return result;
}
static std::wstring InstalledSymbolicLink() {
  wchar_t value[32768]{}; DWORD bytes = sizeof(value), type = 0;
  auto status = RegGetValueW(HKEY_CURRENT_USER, L"Software\\BShare\\VirtualCamera", L"DeviceSymbolicLink",
      RRF_RT_REG_SZ, &type, value, &bytes);
  return status == ERROR_SUCCESS ? std::wstring(value) : L"";
}
static HRESULT SaveCameraIdentity(IMFVirtualCamera* camera) {
  wchar_t* value = nullptr; UINT32 length = 0;
  HRESULT hr = camera->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &value, &length);
  if (FAILED(hr)) return hr;
  HKEY key = nullptr;
  LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\BShare\\VirtualCamera", 0, KEY_SET_VALUE, &key);
  if (status == ERROR_SUCCESS) {
    status = RegSetValueExW(key, L"DeviceSymbolicLink", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(value), DWORD((length + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
  }
  CoTaskMemFree(value);
  return HRESULT_FROM_WIN32(status);
}
static std::string JsonString(const std::wstring& value) {
  if (value.empty()) return "BShare";
  int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), int(value.size()), nullptr, 0, nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), int(value.size()), utf8.data(), size, nullptr, nullptr);
  std::string result;
  for (unsigned char c : utf8) {
    if (c == '"' || c == '\\') result += '\\';
    if (c >= 0x20) result += char(c);
  }
  return result;
}
static HRESULT Enumerate(ComPtr<IMFActivate>& selected, std::wstring& name) {
  // Device identity is the instance link returned by Start(), never a localized
  // friendly-name suffix. Registration persists this in the protected user key.
  const auto expected = InstalledSymbolicLink();
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1); if (FAILED(hr)) return hr;
  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return hr;
  IMFActivate** devices = nullptr; UINT32 count = 0;
  hr = MFEnumDeviceSources(attributes.Get(), &devices, &count); if (FAILED(hr)) return hr;
  for (UINT32 i = 0; i < count; ++i) {
    wchar_t* text = nullptr; wchar_t* link = nullptr; UINT32 length = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &text, &length))) {
      if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link, &length))) {
        if (!expected.empty() && _wcsicmp(link, expected.c_str()) == 0) { selected = devices[i]; name = text; }
        CoTaskMemFree(link);
      }
      CoTaskMemFree(text);
    }
    devices[i]->Release();
  }
  CoTaskMemFree(devices);
  return S_OK;
}
static HRESULT Probe(IMFActivate* activate, unsigned frames, bool lifecycle_test = false,
    const std::function<void()>& release_activation = {}) {
  ComPtr<IMFMediaSource> source;
  HRESULT hr = activate->ActivateObject(IID_PPV_ARGS(&source)); if (FAILED(hr)) { std::cerr << "ActivateObject "; return hr; }
  if (release_activation) release_activation();
  ComPtr<IMFSourceReader> reader;
  hr = MFCreateSourceReaderFromMediaSource(source.Get(), nullptr, &reader);
  if (FAILED(hr)) { std::cerr << "CreateSourceReader "; source->Shutdown(); return hr; }
  hr = reader->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
  ComPtr<IMFMediaType> type;
  hr = MFCreateMediaType(&type);
  if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, type.Get());
  if (FAILED(hr)) std::cerr << "SetCurrentMediaType ";
  unsigned received = 0, changed_pairs = 0; uint64_t sum = 0; size_t bytes = 0; uint64_t hash = 14695981039346656037ull;
  double first_mean = 0, last_mean = 0; uint64_t previous_frame_hash = 0, first_frame_hash = 0;
  for (unsigned i = 0; i < frames && SUCCEEDED(hr); ++i) {
    DWORD stream = 0, flags = 0; LONGLONG timestamp = 0; ComPtr<IMFSample> sample;
    hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &timestamp, &sample);
    if (FAILED(hr)) std::cerr << "ReadSample ";
    if (SUCCEEDED(hr) && sample) {
      ComPtr<IMFMediaBuffer> buffer; hr = sample->ConvertToContiguousBuffer(&buffer); if (FAILED(hr)) break;
      BYTE* data = nullptr; DWORD length = 0; hr = buffer->Lock(&data, nullptr, &length); if (FAILED(hr)) break;
      uint64_t frame_sum = 0, frame_bytes = 0, frame_hash = 14695981039346656037ull;
      for (DWORD j = 0; j < length; j += 64) {
        sum += data[j]; ++bytes; hash ^= data[j]; hash *= 1099511628211ull;
        frame_sum += data[j]; ++frame_bytes; frame_hash ^= data[j]; frame_hash *= 1099511628211ull;
      }
      last_mean = frame_bytes ? double(frame_sum) / frame_bytes : 0;
      if (!received) { first_mean = last_mean; first_frame_hash = frame_hash; }
      else if (previous_frame_hash != frame_hash) ++changed_pairs;
      previous_frame_hash = frame_hash;
      buffer->Unlock(); ++received;
    }
  }
  reader.Reset(); source->Shutdown();
  if (lifecycle_test && SUCCEEDED(hr)) {
    ComPtr<IKsControl> controls;
    hr = source.As(&controls);
    if (SUCCEEDED(hr)) {
      KSPROPERTY property{PROPSETID_SIMPLEMEDIASOURCE_CUSTOMCONTROL, KSPROPERTY_SIMPLEMEDIASOURCE_CUSTOMCONTROL_COLORING, KSPROPERTY_TYPE_GET};
      KSPROPERTY_SIMPLEMEDIASOURCE_CUSTOMCONTROL_COLORMODE_S data{}; ULONG returned = 0;
      HRESULT property_hr = controls->KsProperty(&property, sizeof(property), &data, sizeof(data), &returned);
      if (property_hr != MF_E_SHUTDOWN) { std::cerr << "Post-shutdown property must return MF_E_SHUTDOWN "; hr = E_FAIL; }
    }
  }
  if (!release_activation) activate->ShutdownObject();
  if (SUCCEEDED(hr)) std::cout << "{\"frames\":" << received << ",\"sampleMean\":" << (bytes ? double(sum) / bytes : 0)
      << ",\"firstFrameMean\":" << first_mean << ",\"lastFrameMean\":" << last_mean
      << ",\"changedFramePairs\":" << changed_pairs
      << ",\"firstFrameHash\":\"" << std::hex << first_frame_hash
      << "\",\"lastFrameHash\":\"" << previous_frame_hash << "\""
      << ",\"sampleHash\":\"" << std::hex << hash << "\"}" << std::endl;
  return hr;
}
int wmain(int argc, wchar_t** argv) {
  if (argc < 2) { std::cerr << "Usage: bshare-camera --status|--install|--uninstall|--register-source DLL|--register-user-source DLL|--probe [frames]|--publish-test\n"; return 2; }
  const std::wstring command = argv[1];
  const bool direct_probe = command == L"--probe-direct" || command == L"--probe-direct-cycle";
  if (direct_probe && argc < 3) { Error(E_INVALIDARG); return 1; }
  // Direct probes load the source DLL in this process and use ordinary Media
  // Foundation. They do not register a device or need the Windows 11 API.
  if (!direct_probe && !Supported()) {
    if (command == L"--status") { std::cout << "{\"supported\":false,\"registered\":false,\"sourceRegistered\":false,\"deviceName\":\"BShare Windows Virtual Camera\"}\n"; return 0; }
    Error(HRESULT_FROM_WIN32(ERROR_OLD_WIN_VERSION)); return 1;
  }
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr)) { Error(hr); return 1; }
  hr = MFStartup(MF_VERSION);
  if (FAILED(hr)) { Error(hr); CoUninitialize(); return 1; }
  if (direct_probe) {
    HMODULE module = LoadLibraryW(argv[2]);
    if (!module) hr = HRESULT_FROM_WIN32(GetLastError());
    else {
      using Factory = HRESULT (__stdcall*)(REFCLSID, REFIID, void**);
      auto function = reinterpret_cast<Factory>(GetProcAddress(module, "DllGetClassObject"));
      ComPtr<IClassFactory> factory; ComPtr<IMFActivate> activate;
      hr = function ? function(CLSID_VirtualCameraMediaSource, IID_PPV_ARGS(&factory)) : E_NOINTERFACE;
      if (SUCCEEDED(hr)) hr = factory->CreateInstance(nullptr, IID_PPV_ARGS(&activate));
      if (SUCCEEDED(hr)) hr = activate->SetString(BSHARE_PRODUCER_SID, bshare::virtual_camera::CurrentUserSid().c_str());
      if (SUCCEEDED(hr)) hr = activate->SetString(BSHARE_PRODUCER_CREDENTIAL, bshare::virtual_camera::ProducerCredential(true).c_str());
      if (SUCCEEDED(hr)) hr = Probe(activate.Get(), argc > 3 ? std::stoul(argv[3]) : 15, command == L"--probe-direct-cycle");
      // ShutdownObject must clear its cached source so reactivation constructs
      // a fresh source, stream, allocator and pipe worker.
      if (SUCCEEDED(hr) && command == L"--probe-direct-cycle") hr = Probe(activate.Get(), 5, true);
      if (SUCCEEDED(hr) && command == L"--probe-direct-cycle")
        hr = Probe(activate.Get(), 5, false, [&activate] { activate.Reset(); });
      activate.Reset(); factory.Reset(); FreeLibrary(module);
    }
  } else if (command == L"--unregister-source") {
    hr = argc == 3 ? UnregisterSource(argv[2]) : E_INVALIDARG;
  } else if (command == L"--register-source" || command == L"--register-user-source") {
    hr = argc == 3 ? RegisterSource(command == L"--register-source", argv[2]) : E_INVALIDARG;
  } else if (command == L"--install" || command == L"--uninstall") {
    ComPtr<IMFVirtualCamera> camera; hr = Camera(camera);
    if (SUCCEEDED(hr)) {
      if (command == L"--install") {
        const auto sid = bshare::virtual_camera::CurrentUserSid();
        const auto credential = bshare::virtual_camera::ProducerCredential(true);
        hr = sid.empty() ? E_FAIL : camera->SetString(BSHARE_PRODUCER_SID, sid.c_str());
        if (SUCCEEDED(hr)) hr = credential.empty() ? E_FAIL : camera->SetString(BSHARE_PRODUCER_CREDENTIAL, credential.c_str());
        if (SUCCEEDED(hr)) hr = camera->Start(nullptr);
        if (SUCCEEDED(hr)) hr = SaveCameraIdentity(camera.Get());
      } else hr = camera->Remove();
      // System lifetime keeps it registered when this object is released.
    }
  } else if (command == L"--publish-test") {
    bshare::virtual_camera::FramePublisher publisher;
    std::vector<uint8_t> pixels(640 * 480 * 4);
    for (size_t i = 0; i < pixels.size(); i += 4) { pixels[i] = 25; pixels[i+1] = 80; pixels[i+2] = 230; pixels[i+3] = 255; }
    for (unsigned i = 0; i < 450; ++i) { publisher.Publish(pixels.data(), 640, 480, 640 * 4); Sleep(33); }
    publisher.Clear();
  } else {
    ComPtr<IMFActivate> device; std::wstring name;
    hr = Enumerate(device, name);
    if (SUCCEEDED(hr) && command == L"--status") std::cout << "{\"supported\":true,\"registered\":" << (device ? "true" : "false")
        << ",\"sourceRegistered\":" << (SourceRegistered() ? "true" : "false")
        << ",\"deviceName\":\"" << JsonString(name) << "\"}\n";
    else if (SUCCEEDED(hr) && command == L"--probe") hr = device ? Probe(device.Get(), argc > 2 ? std::stoul(argv[2]) : 15) : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    else hr = E_INVALIDARG;
  }
  MFShutdown(); CoUninitialize();
  if (FAILED(hr)) { Error(hr); return 1; }
  return 0;
}
