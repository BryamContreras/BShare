#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <unknwn.h>
#include <ole2.h>
#include <propvarutil.h>
#include <initguid.h>
#include <ks.h>
#include <ksproxy.h>
#include <ksmedia.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <mfvirtualcamera.h>
#include <strsafe.h>
#include <wil/cppwinrt.h>
#include <wil/result.h>
#include <wil/com.h>
#include <wil/resource.h>
#include "VirtualCameraMediaSource.h"
#include "SimpleFrameGenerator.h"
#include "SimpleMediaSource.h"
#include "SimpleMediaStream.h"
#include "VirtualCameraMediaSourceActivate.h"
#define DEBUG_MSG(...) ((void)0)
namespace wilEx {
template<typename T>
wil::unique_cotaskmem_array_ptr<T> make_unique_cotaskmem_array(size_t count) {
  wil::unique_cotaskmem_array_ptr<T> result;
  using Element = typename wil::details::element_traits<T>::type;
  void* memory = CoTaskMemAlloc(sizeof(Element) * count);
  if (memory) { ZeroMemory(memory, sizeof(Element) * count); result.reset(reinterpret_cast<Element*>(memory), count); }
  return result;
}
}
namespace winrt {
template<> bool is_guid_of<IMFMediaSourceEx>(guid const&) noexcept;
template<> bool is_guid_of<IMFMediaStream2>(guid const&) noexcept;
template<> bool is_guid_of<IMFActivate>(guid const&) noexcept;
}
