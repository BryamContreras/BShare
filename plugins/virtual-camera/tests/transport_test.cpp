#include "pch.h"
#include <iostream>
#include <sstream>
#include <iomanip>
using namespace bshare::virtual_camera;
static void Check(bool condition, const char* description) {
  if (!condition) { std::cerr << description << '\n'; std::exit(1); }
}
int main() {
  Check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)), "COM");
  Check(SUCCEEDED(MFStartup(MF_VERSION)), "MF");
  {
    SimpleFrameGenerator generator;
    std::wostringstream id;
    id << std::hex << std::setfill(L'0') << std::setw(32) << GetCurrentProcessId();
    const auto credential = id.str();
    generator.SetProducerIdentity(CurrentUserSid(), credential);
    wil::com_ptr_nothrow<IMFMediaType> type;
    Check(SUCCEEDED(MFCreateMediaType(&type)), "media type");
    type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    MFSetAttributeSize(type.get(), MF_MT_FRAME_SIZE, 1280, 720);
    Check(SUCCEEDED(generator.Initialize(type.get())), "generator init");
    std::vector<uint8_t> output(1280 * 720 * 4);
    Check(SUCCEEDED(generator.CreateFrame(output.data(), DWORD(output.size()), 1280*4, 0)), "slate frame");
    auto slate = output;
    Check(output[0] == 32 && output[1] == 23 && output[2] == 19, "slate background");
    {
      FramePublisher publisher(credential);
      FramePublisher duplicate(credential);
      std::vector<uint8_t> frame(640 * 480 * 4);
      for (size_t i = 0; i < frame.size(); i += 4) { frame[i] = 10; frame[i+1] = 20; frame[i+2] = 240; frame[i+3] = 255; }
      Check(!publisher.Publish(frame.data(), 0, 480, 2560), "reject zero width");
      Check(!publisher.Publish(frame.data(), 640, 480, 3), "reject short stride");
      Check(!duplicate.Publish(frame.data(), 640, 480, 2560), "reject competing producer");
      bool received = false;
      for (unsigned i = 0; i < 60; ++i) {
        publisher.Publish(frame.data(), 640, 480, 2560);
        Sleep(35);
        Check(SUCCEEDED(generator.CreateFrame(output.data(), DWORD(output.size()), 1280*4, 0)), "live frame");
        if (output[(360*1280+640)*4+2] == 240) { received = true; break; }
      }
      Check(received, "real local IPC frame");
      Check(output[0] == 0, "aspect-fit pillarbox");
      Sleep(1800);
      generator.CreateFrame(output.data(), DWORD(output.size()), 1280*4, 0);
      Check(output[(360*1280+640)*4+2] == 240, "heartbeat retains static video");
      publisher.Clear(); Sleep(100);
      generator.CreateFrame(output.data(), DWORD(output.size()), 1280*4, 0);
      Check(output == slate, "clear restores exact waiting slate");
      publisher.Publish(frame.data(), 640, 480, 2560); Sleep(100);
    }
    Sleep(150);
    generator.CreateFrame(output.data(), DWORD(output.size()), 1280*4, 0);
    Check(output == slate, "producer exit restores waiting slate");
  }
  MFShutdown(); CoUninitialize();
  std::cout << "Slate, BGRA pipe, aspect ratio, clear, producer exit and bounded disposal passed.\n";
}
