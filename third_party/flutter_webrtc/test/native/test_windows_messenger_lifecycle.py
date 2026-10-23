#!/usr/bin/env python3
"""Check the production Windows messenger guard and desktop event proxy.

Small C API doubles model Flutter invalidating its engine before destroying
plugin registrars. The real guard, event proxy and codec are compiled unchanged.
No Windows app or engine is started; the installer job checks actual Windows
startup and shutdown separately.
"""

from pathlib import Path
import argparse
import os
import platform
import resource
import shlex
import shutil
import subprocess
import tempfile


CORE_API = r'''
#pragma once
struct FlutterDesktopMessenger;
using FlutterDesktopMessengerRef = FlutterDesktopMessenger*;
extern "C" {
FlutterDesktopMessengerRef FlutterDesktopMessengerAddRef(FlutterDesktopMessengerRef);
void FlutterDesktopMessengerRelease(FlutterDesktopMessengerRef);
bool FlutterDesktopMessengerIsAvailable(FlutterDesktopMessengerRef);
FlutterDesktopMessengerRef FlutterDesktopMessengerLock(FlutterDesktopMessengerRef);
void FlutterDesktopMessengerUnlock(FlutterDesktopMessengerRef);
}
'''


HARNESS = r'''
#include <cstdint>
#include "engine_aware_messenger.h"
#include "flutter_common.h"
#include "task_runner.h"

#include <cassert>
#include <iostream>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

struct FlutterDesktopMessenger {
  int refs = 1;
  bool available = true;
  int locks = 0;
  int unlocks = 0;
  std::mutex mutex;
  std::thread::id platform_thread = std::this_thread::get_id();
};
thread_local bool core_locked = false;

extern "C" FlutterDesktopMessengerRef FlutterDesktopMessengerAddRef(
    FlutterDesktopMessengerRef core) {
  ++core->refs;
  return core;
}
extern "C" void FlutterDesktopMessengerRelease(FlutterDesktopMessengerRef core) {
  assert(core->refs > 1);
  --core->refs;
}
extern "C" bool FlutterDesktopMessengerIsAvailable(FlutterDesktopMessengerRef core) {
  assert(std::this_thread::get_id() == core->platform_thread || core_locked);
  return core->available;
}
extern "C" FlutterDesktopMessengerRef FlutterDesktopMessengerLock(
    FlutterDesktopMessengerRef core) {
  core->mutex.lock();
  assert(!core_locked);
  core_locked = true;
  ++core->locks;
  return core;
}
extern "C" void FlutterDesktopMessengerUnlock(FlutterDesktopMessengerRef core) {
  assert(core_locked);
  core_locked = false;
  ++core->unlocks;
  core->mutex.unlock();
}

class TestMessenger : public BinaryMessenger {
 public:
  explicit TestMessenger(FlutterDesktopMessengerRef core) : core_(core) {}
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
  mutable int sent = 0;
  int registrations = 0;
  int unregisters = 0;
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply reply) const override {
    assert(core_->available && "A real Windows delegate would dereference null");
    ++sent;
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string& name,
                         flutter::BinaryMessageHandler handler) override {
    assert(core_->available && "A real Windows delegate would dereference null");
    if (handler) {
      ++registrations;
      handlers[name] = std::move(handler);
    } else {
      ++unregisters;
      handlers.erase(name);
    }
  }
  void Listen(const std::string& name) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    auto message = codec.EncodeMethodCall(MethodCall("listen", nullptr));
    bool replied = false;
    auto handler = handlers.at(name);
    handler(message->data(), message->size(),
            [&](const uint8_t* bytes, size_t size) {
              assert(size > 0 && bytes[0] == 0);
              replied = true;
            });
    assert(replied);
  }
 private:
  FlutterDesktopMessengerRef core_;
};

class TestRunner : public TaskRunner {
 public:
  std::vector<TaskClosure> tasks;
  void EnqueueTask(TaskClosure task) override { tasks.push_back(std::move(task)); }
  void Flush() {
    auto pending = std::move(tasks);
    tasks.clear();
    for (auto& task : pending) task();
  }
};

void CheckLiveDispose() {
  FlutterDesktopMessenger core;
  TestMessenger delegate(&core);
  {
    flutter_webrtc_plugin::EngineAwareMessenger guarded(&delegate, &core);
    assert(core.refs == 2);
    TestRunner runner;
    auto proxy = EventChannelProxy::Create(&guarded, &runner, "peer");
    delegate.Listen("peer");
    proxy->Success(EncodableValue("frame"));
    runner.Flush();
    assert(delegate.sent == 1);
    proxy->Success(EncodableValue("late frame"));
    proxy.reset();
    assert(delegate.handlers.empty() && delegate.unregisters == 1);
    runner.Flush();
    assert(delegate.sent == 1);
    int replies = 0;
    guarded.Send("request", nullptr, 0,
                 [&](const uint8_t*, size_t) { ++replies; });
    assert(replies == 1);
    assert(core.locks == 0 && core.unlocks == 0);
  }
  assert(core.refs == 1);
}

void CheckEngineDestroyedFirst() {
  FlutterDesktopMessenger core;
  TestMessenger delegate(&core);
  {
    flutter_webrtc_plugin::EngineAwareMessenger guarded(&delegate, &core);
    TestRunner runner;
    auto proxy = EventChannelProxy::Create(&guarded, &runner, "peer");
    delegate.Listen("peer");
    proxy->Success(EncodableValue("frame before shutdown"));
    // This is the exact ordering in FlutterWindowsEngine::~: invalidate the
    // messenger first, then destroy plugin-owned event channels and registrars.
    core.available = false;
    runner.Flush();
    assert(delegate.sent == 0);
    proxy->Success(EncodableValue("late frame"));
    proxy.reset();
    runner.Flush();
    guarded.SetMessageHandler("late handler", nullptr);
    guarded.Send("late request", nullptr, 0);
    assert(delegate.sent == 0 && delegate.unregisters == 0);
    assert(delegate.registrations == 1);
    // The real engine destroys this map/dispatcher after registrar cleanup.
    // Never invoke callbacks from an engine that has already been invalidated.
    delegate.handlers.clear();
  }
  assert(core.refs == 1);
}

void CheckWorkerLocking() {
  FlutterDesktopMessenger core;
  TestMessenger delegate(&core);
  {
    flutter_webrtc_plugin::EngineAwareMessenger guarded(&delegate, &core);
    std::thread worker([&] { guarded.Send("worker", nullptr, 0); });
    worker.join();
    core.available = false;
    std::thread stopped_worker([&] {
      guarded.SetMessageHandler("worker", nullptr);
      guarded.Send("worker", nullptr, 0);
    });
    stopped_worker.join();
    assert(delegate.sent == 1 && delegate.unregisters == 0);
    assert(core.locks == 3 && core.unlocks == 3);
  }
  assert(core.refs == 1);
}

int main() {
  for (int iteration = 0; iteration < 100; ++iteration) {
    CheckLiveDispose();
    CheckEngineDestroyedFirst();
    CheckWorkerLocking();
  }
  std::cout << "Windows messenger: 100 live unregister cycles, 100 invalidated "
               "engine shutdowns and 300 balanced worker locks; native refs "
               "released, queued events expire, invalid delegates untouched.\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    plugin = Path(__file__).resolve().parents[2]
    source = (plugin / "windows/flutter_webrtc_plugin.cc").read_text()
    declarations = source.split("// Reverse member destruction", 1)[1]
    assert declarations.index(" messenger_;") < declarations.index(" channel_;")
    assert declarations.index(" channel_;") < declarations.index(" task_runner_;")
    assert declarations.index(" task_runner_;") < declarations.index(" webrtc_;")
    flutter = Path(shutil.which("flutter")).resolve().parents[1]
    arch = "arm64" if platform.machine() in ("aarch64", "arm64") else "x64"
    gtk_flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "gtk+-3.0"], text=True))
    with tempfile.TemporaryDirectory(prefix="bshare-windows-messenger-") as temp:
        directory = Path(temp)
        (directory / "flutter_messenger.h").write_text(CORE_API)
        test_source = directory / "test.cc"
        test_source.write_text(HARNESS)
        binary = directory / "test"
        sanitizers = ["-fsanitize=address,undefined"] if args.sanitize else []
        subprocess.run([
            os.environ.get("CXX", "c++"), "-std=c++17", "-O0", "-g",
            "-Wall", "-Werror", "-fno-omit-frame-pointer", *sanitizers,
            "-ffunction-sections", "-fdata-sections", "-pthread",
            f"-I{directory}", f"-I{plugin / 'windows'}",
            f"-I{plugin / 'common/cpp/include'}",
            "-isystem", str(plugin / "linux/flutter/include"),
            f"-I{flutter / 'bin/cache/artifacts/engine' / ('linux-' + arch)}",
            *gtk_flags, str(test_source),
            str(plugin / "common/cpp/src/flutter_common.cc"),
            str(plugin / "linux/flutter/standard_codec.cc"),
            "-Wl,--gc-sections", "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
