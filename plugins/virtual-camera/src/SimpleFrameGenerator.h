#pragma once
#include "bshare_frame_publisher.h"
#include <memory>

// Runs in the camera host; it needs no BShare process for the waiting slate.
class SimpleFrameGenerator final {
 public:
  SimpleFrameGenerator() = default;
  ~SimpleFrameGenerator();
  HRESULT Initialize(IMFMediaType* media_type);
  void SetProducerIdentity(std::wstring sid, std::wstring credential);
  HRESULT CreateFrame(BYTE* output, DWORD length, LONG pitch, ULONG unused);
 private:
  void Receive();
  bool Read(HANDLE pipe, void* output, DWORD count);
  void RenderBgra(std::vector<uint8_t>& output);
  std::wstring sid_;
  std::wstring credential_;
  std::wstring pipe_name_;
  std::thread receiver_;
  HANDLE stop_event_ = nullptr;
  std::mutex mutex_;
  std::vector<uint8_t> pixels_;
  uint32_t input_width_ = 0, input_height_ = 0;
  ULONGLONG last_frame_ = 0;
  uint32_t width_ = 0, height_ = 0;
  GUID subtype_ = GUID_NULL;
  std::vector<uint8_t> slate_;
  ULONGLONG next_frame_ = 0;
};
