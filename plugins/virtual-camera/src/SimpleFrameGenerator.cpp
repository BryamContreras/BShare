#include "pch.h"
#include <cmath>
#include <aclapi.h>
using namespace bshare::virtual_camera;

SimpleFrameGenerator::~SimpleFrameGenerator() {
  if (stop_event_) SetEvent(stop_event_);
  if (receiver_.joinable()) receiver_.join();
  if (stop_event_) CloseHandle(stop_event_);
}
void SimpleFrameGenerator::SetProducerIdentity(std::wstring sid, std::wstring credential) {
  sid_ = std::move(sid); credential_ = std::move(credential);
}
HRESULT SimpleFrameGenerator::Initialize(IMFMediaType* type) {
  RETURN_IF_FAILED(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &width_, &height_));
  RETURN_IF_FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype_));
  RETURN_HR_IF(MF_E_INVALIDMEDIATYPE, width_ != 1280 || height_ != 720 ||
      (subtype_ != MFVideoFormat_NV12 && subtype_ != MFVideoFormat_RGB32));
  // Draw once with GDI into a top-down DIB; no window or UI thread is involved.
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width_;
  info.bmiHeader.biHeight = -LONG(height_);
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC dc = CreateCompatibleDC(nullptr);
  RETURN_HR_IF_NULL(E_OUTOFMEMORY, dc);
  void* memory = nullptr;
  HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &memory, nullptr, 0);
  if (!bitmap) { DeleteDC(dc); return E_OUTOFMEMORY; }
  HGDIOBJ previous = SelectObject(dc, bitmap);
  RECT rect{0, 0, LONG(width_), LONG(height_)};
  HBRUSH brush = CreateSolidBrush(RGB(19, 23, 32));
  FillRect(dc, &rect, brush);
  DeleteObject(brush);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(235, 238, 245));
  HFONT font = CreateFontW(-52, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  HGDIOBJ previous_font = SelectObject(dc, font);
  rect.top = 235; rect.bottom = 315;
  DrawTextW(dc, L"BShare", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  SelectObject(dc, previous_font);
  DeleteObject(font);
  font = CreateFontW(-29, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
  previous_font = SelectObject(dc, font);
  SetTextColor(dc, RGB(175, 184, 202));
  rect.top = 335; rect.bottom = 385;
  DrawTextW(dc, L"No hay dispositivo de video conectado", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  SetTextColor(dc, RGB(126, 139, 159));
  rect.top = 385; rect.bottom = 435;
  DrawTextW(dc, L"No video device connected", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  slate_.assign(static_cast<uint8_t*>(memory), static_cast<uint8_t*>(memory) + size_t(width_) * height_ * 4);
  SelectObject(dc, previous_font); DeleteObject(font);
  SelectObject(dc, previous); DeleteObject(bitmap); DeleteDC(dc);
  for (size_t i = 3; i < slate_.size(); i += 4) slate_[i] = 255;
  if (!receiver_.joinable() && !sid_.empty() && ValidCredential(credential_)) {
    pipe_name_ = PipeName(sid_, credential_);
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    RETURN_HR_IF_NULL(HRESULT_FROM_WIN32(GetLastError()), stop_event_);
    receiver_ = std::thread([this] { Receive(); });
  }
  next_frame_ = 0;
  return S_OK;
}
bool SimpleFrameGenerator::Read(HANDLE pipe, void* output, DWORD count) {
  HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!event) return false;
  bool ok = true;
  while (count && ok) {
    OVERLAPPED operation{}; operation.hEvent = event; ResetEvent(event);
    DWORD bytes = 0;
    if (!ReadFile(pipe, output, count, &bytes, &operation)) {
      if (GetLastError() != ERROR_IO_PENDING) { ok = false; break; }
      const HANDLE events[] = {stop_event_, event};
      DWORD result = WaitForMultipleObjects(2, events, FALSE, INFINITE);
      if (result != WAIT_OBJECT_0 + 1) {
        CancelIoEx(pipe, &operation); WaitForSingleObject(event, INFINITE); ok = false; break;
      }
      ok = GetOverlappedResult(pipe, &operation, &bytes, FALSE) != FALSE;
    }
    if (!bytes) { ok = false; break; }
    output = static_cast<uint8_t*>(output) + bytes;
    count -= bytes;
  }
  CloseHandle(event);
  return ok;
}
void SimpleFrameGenerator::Receive() {
  while (WaitForSingleObject(stop_event_, 0) == WAIT_TIMEOUT) {
    HANDLE pipe = CreateFileW(pipe_name_.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) { WaitForSingleObject(stop_event_, 150); continue; }
    // A different Windows user cannot impersonate the producer by squatting on
    // its predictable pipe name. Verify the pipe's owner before reading pixels.
    PSID expected = nullptr, actual = nullptr;
    PSECURITY_DESCRIPTOR security = nullptr;
    bool trusted = ConvertStringSidToSidW(sid_.c_str(), &expected) &&
        GetSecurityInfo(pipe, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION,
            &actual, nullptr, nullptr, nullptr, &security) == ERROR_SUCCESS &&
        actual && EqualSid(expected, actual);
    if (expected) LocalFree(expected);
    if (security) LocalFree(security);
    if (!trusted) { CloseHandle(pipe); WaitForSingleObject(stop_event_, 250); continue; }
    while (WaitForSingleObject(stop_event_, 0) == WAIT_TIMEOUT) {
      WireHeader header;
      if (!Read(pipe, &header, sizeof(header))) break;
      if (header.magic != kWireMagic || header.version != 1 || header.reserved ||
          (header.bytes && (!header.width || !header.height || header.width > 4096 || header.height > 4096 ||
            uint64_t(header.width) * header.height > kMaxPixels ||
            header.bytes != uint64_t(header.width) * header.height * 4))) break;
      std::vector<uint8_t> frame(header.bytes);
      if (header.bytes && !Read(pipe, frame.data(), header.bytes)) break;
      { std::lock_guard lock(mutex_); pixels_ = std::move(frame); input_width_ = header.width;
        input_height_ = header.height; last_frame_ = GetTickCount64(); }
    }
    { std::lock_guard lock(mutex_); pixels_.clear(); }
    CloseHandle(pipe);
  }
}
void SimpleFrameGenerator::RenderBgra(std::vector<uint8_t>& output) {
  std::lock_guard lock(mutex_);
  if (pixels_.empty() || GetTickCount64() - last_frame_ > 1500) { output = slate_; return; }
  output.assign(size_t(width_) * height_ * 4, 0);
  double scale = (std::min)(double(width_) / input_width_, double(height_) / input_height_);
  uint32_t draw_width = (std::max)(1u, uint32_t(input_width_ * scale));
  uint32_t draw_height = (std::max)(1u, uint32_t(input_height_ * scale));
  const uint32_t left = (width_ - draw_width) / 2, top = (height_ - draw_height) / 2;
  for (uint32_t y = 0; y < draw_height; ++y) {
    auto* dst = output.data() + (size_t(y + top) * width_ + left) * 4;
    auto* src = pixels_.data() + size_t(uint64_t(y) * input_height_ / draw_height) * input_width_ * 4;
    for (uint32_t x = 0; x < draw_width; ++x)
      std::memcpy(dst + x * 4, src + (uint64_t(x) * input_width_ / draw_width) * 4, 4);
  }
}
HRESULT SimpleFrameGenerator::CreateFrame(BYTE* output, DWORD length, LONG pitch, ULONG) {
  RETURN_HR_IF(E_INVALIDARG, !output || pitch < LONG(width_));
  auto now = GetTickCount64();
  if (next_frame_ > now) Sleep(DWORD((std::min)(next_frame_ - now, 34ull)));
  next_frame_ = (std::max)(next_frame_ + 33, GetTickCount64());
  std::vector<uint8_t> bgra;
  RenderBgra(bgra);
  if (subtype_ == MFVideoFormat_RGB32) {
    RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER), pitch < LONG(width_ * 4) || uint64_t(pitch) * height_ > length);
    for (uint32_t y = 0; y < height_; ++y) std::memcpy(output + size_t(y) * pitch, bgra.data() + size_t(y) * width_ * 4, width_ * 4);
    return S_OK;
  }
  RETURN_HR_IF(HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER), uint64_t(pitch) * height_ * 3 / 2 > length);
  auto clamp = [](int value) { return uint8_t((std::clamp)(value, 0, 255)); };
  auto yplane = output; auto uvplane = output + size_t(pitch) * height_;
  // BT.601 limited range. Average chroma across every 2x2 pixel block.
  for (uint32_t y = 0; y < height_; y += 2) for (uint32_t x = 0; x < width_; x += 2) {
    int sum_r = 0, sum_g = 0, sum_b = 0;
    for (uint32_t dy = 0; dy < 2; ++dy) for (uint32_t dx = 0; dx < 2; ++dx) {
      auto p = bgra.data() + (size_t(y + dy) * width_ + x + dx) * 4;
      int b = p[0], g = p[1], r = p[2];
      yplane[size_t(y + dy) * pitch + x + dx] = clamp(((66*r + 129*g + 25*b + 128) >> 8) + 16);
      sum_r += r; sum_g += g; sum_b += b;
    }
    uvplane[size_t(y / 2) * pitch + x] = clamp(((-38*sum_r - 74*sum_g + 112*sum_b + 512) >> 10) + 128);
    uvplane[size_t(y / 2) * pitch + x + 1] = clamp(((112*sum_r - 94*sum_g - 18*sum_b + 512) >> 10) + 128);
  }
  return S_OK;
}
