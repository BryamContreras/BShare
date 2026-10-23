#!/usr/bin/env python3
"""Exercise the production desktop EventChannel proxy and close/dispose methods.

The close/dispose methods are copied unchanged into a small ownership fixture;
the proxy, Linux EventChannel wrapper and codec are compiled from production.
No device, application process or Flutter build is needed. Add --sanitize when
the compiler's ASan and UBSan runtimes are installed.
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


def production_method(source, signature):
    start = source.index(signature)
    cursor = source.index("{", start)
    depth = 1
    end = cursor + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = r'''
#include "flutter_common.h"
#include "task_runner.h"

#include <cassert>
#include <iostream>
#include <map>
#include <vector>

#ifdef USE_REAL_PEER
#include "libwebrtc.h"
#include "rtc_peerconnection.h"
using libwebrtc::RTCPeerConnection;
libwebrtc::scoped_refptr<libwebrtc::RTCPeerConnectionFactory> real_factory;
using PeerRef = libwebrtc::scoped_refptr<RTCPeerConnection>;
#endif

class TestMessenger : public BinaryMessenger {
 public:
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
  mutable int sent = 0;

  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply reply) const override {
    ++sent;
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string& name,
                         flutter::BinaryMessageHandler handler) override {
    if (handler) handlers[name] = std::move(handler);
    else handlers.erase(name);
  }
  void Call(const std::string& name, const std::string& method) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    auto message = codec.EncodeMethodCall(MethodCall(method, nullptr));
    bool replied = false;
    std::vector<uint8_t> response;
    // Keep the handler alive if it unregisters itself during this request.
    auto handler = handlers.at(name);
    handler(message->data(), message->size(),
            [&](const uint8_t* bytes, size_t size) {
              replied = true;
              response.assign(bytes, bytes + size);
            });
    assert(replied);
    assert(!response.empty() && response[0] == 0);
  }
};

class TestRunner : public TaskRunner {
 public:
  std::vector<TaskClosure> tasks;
  void EnqueueTask(TaskClosure task) override {
    tasks.push_back(std::move(task));
  }
  void Flush() {
    auto pending = std::move(tasks);
    tasks.clear();
    for (auto& task : pending) task();
  }
};

#ifndef USE_REAL_PEER
class RTCPeerConnection {
 public:
  int closes = 0;
  int deregisters = 0;
  bool closed = false;
  void Close() {
    if (closed) return;
    ++closes;
    closed = true;
  }
  // No state getter: the real implementation releases its internal peer in
  // Close(), so querying that state afterwards is invalid.
  void DeRegisterRTCPeerConnectionObserver() { ++deregisters; }
};
using PeerRef = std::shared_ptr<RTCPeerConnection>;
#endif

struct TestObserver {
  std::unique_ptr<EventChannelProxy> channel;
};

struct TestBase {
  std::map<std::string, PeerRef> peerconnections_;
  std::map<std::string, std::shared_ptr<TestObserver>> peerconnection_observers_;
};

class TestResult : public MethodResultProxy {
 public:
  explicit TestResult(int* successes) : successes_(successes) {}
  void Success() override { ++*successes_; }
  void Success(const EncodableValue&) override { assert(false); }
  void Error(const std::string&, const std::string&,
             const EncodableValue&) override { assert(false); }
  void Error(const std::string&, const std::string&) override { assert(false); }
  void NotImplemented() override { assert(false); }
 private:
  int* successes_;
};

class FlutterPeerConnection {
 public:
  explicit FlutterPeerConnection(TestBase* base) : base_(base) {}
  void RTCPeerConnectionClose(RTCPeerConnection*, const std::string&,
                               std::unique_ptr<MethodResultProxy>);
  void RTCPeerConnectionDispose(RTCPeerConnection*, const std::string&,
                                 std::unique_ptr<MethodResultProxy>);
 private:
  TestBase* base_;
};

// CLOSE_METHOD
// DISPOSE_METHOD

void CheckProxyDestruction() {
  TestMessenger messenger;
  TestRunner runner;
  auto proxy = EventChannelProxy::Create(&messenger, &runner, "texture");
  messenger.Call("texture", "listen");
  proxy->Success(EncodableValue("queued frame"));
  proxy.reset();
  // The baseline leaves a callback to the destroyed proxy/channel here. Dart
  // sending its final cancel reproduces that invalid read under ASan.
  if (!messenger.handlers.empty()) messenger.Call("texture", "cancel");
  assert(messenger.handlers.empty());
  runner.Flush();
  assert(messenger.sent == 0);
}

void CheckCancelDropsPostedEvents() {
  TestMessenger messenger;
  TestRunner runner;
  auto proxy = EventChannelProxy::Create(&messenger, &runner, "events");
  messenger.Call("events", "listen");
  proxy->Success(EncodableValue("old frame"));
  messenger.Call("events", "cancel");
  runner.Flush();
  assert(messenger.sent == 0);
  messenger.Call("events", "listen");
  proxy->Success(EncodableValue("new frame"));
  runner.Flush();
  assert(messenger.sent == 1);
  messenger.Call("events", "cancel");
  proxy.reset();
  assert(messenger.handlers.empty());
}

void CheckPeer(bool closeFirst) {
  TestMessenger messenger;
  TestRunner runner;
  TestBase base;
  FlutterPeerConnection api(&base);
#ifdef USE_REAL_PEER
  libwebrtc::RTCConfiguration configuration;
  auto pc = real_factory->Create(configuration,
                                libwebrtc::RTCMediaConstraints::Create());
  assert(pc.get());
#else
  auto pc = std::make_shared<RTCPeerConnection>();
#endif
  base.peerconnections_["peer"] = pc;
  auto observer = std::make_shared<TestObserver>();
  observer->channel = EventChannelProxy::Create(&messenger, &runner, "peer");
  base.peerconnection_observers_["peer"] = std::move(observer);
  int successes = 0;
  messenger.Call("peer", "listen");
  if (closeFirst) {
    api.RTCPeerConnectionClose(pc.get(), "peer",
                              std::make_unique<TestResult>(&successes));
#ifndef USE_REAL_PEER
    assert(pc->closes == 1);
#endif
    assert(base.peerconnections_.size() == 1);
    assert(base.peerconnection_observers_.size() == 1);
    // This is Dart's normal close -> subscription.cancel -> dispose sequence.
    // The native channel must remain valid for that cancellation.
  }
  base.peerconnection_observers_.at("peer")->channel->Success(
      EncodableValue("late native event"));
  messenger.Call("peer", "cancel");
  api.RTCPeerConnectionDispose(pc.get(), "peer",
                              std::make_unique<TestResult>(&successes));
#ifndef USE_REAL_PEER
  assert(pc->closes == 1 && pc->deregisters == 1);
#endif
  assert(successes == (closeFirst ? 2 : 1));
  assert(base.peerconnection_observers_.empty());
  assert(base.peerconnections_.empty());
  assert(messenger.handlers.empty());
  runner.Flush();
  assert(messenger.sent == 0);
}

int main() {
#ifdef USE_REAL_PEER
  assert(libwebrtc::LibWebRTC::Initialize());
  real_factory = libwebrtc::LibWebRTC::CreateRTCPeerConnectionFactory();
  assert(real_factory->Initialize());
#endif
  CheckProxyDestruction();
  CheckCancelDropsPostedEvents();
  for (int iteration = 0; iteration < 100; ++iteration) {
    CheckPeer(true);
    CheckPeer(false);
  }
#ifdef USE_REAL_PEER
  real_factory->Terminate();
  real_factory = nullptr;
  libwebrtc::LibWebRTC::Terminate();
  std::cout << "Actual bundled libwebrtc peer Close/Dispose verified.\n";
#endif
  std::cout << "Desktop peer lifecycle: 200 close/dispose cycles; native "
               "handlers removed; cancellation succeeds; queued events expire.\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true",
                        help="exercise HEAD before the local fix (must fail)")
    parser.add_argument("--sanitize", action="store_true",
                        help="enable ASan and UBSan (requires their runtimes)")
    parser.add_argument("--real-peer", action="store_true",
                        help="use real peers from the bundled libwebrtc.so")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    plugin = Path(__file__).resolve().parents[2]
    root = plugin.parents[1]
    peer_path = plugin / "common/cpp/src/flutter_peerconnection.cc"
    proxy_path = plugin / "common/cpp/src/flutter_common.cc"

    def source(path):
        if args.baseline:
            return subprocess.check_output(
                ["git", "show", f"HEAD:{path.relative_to(root)}"],
                cwd=root, text=True)
        return path.read_text()

    methods = source(peer_path)
    harness = HARNESS.replace("// CLOSE_METHOD", production_method(
        methods, "void FlutterPeerConnection::RTCPeerConnectionClose("))
    harness = harness.replace("// DISPOSE_METHOD", production_method(
        methods, "void FlutterPeerConnection::RTCPeerConnectionDispose("))
    flutter = Path(shutil.which("flutter")).resolve().parents[1]
    arch = "arm64" if platform.machine() in ("aarch64", "arm64") else "x64"
    gtk_flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "gtk+-3.0"], text=True))
    with tempfile.TemporaryDirectory(prefix="bshare-peer-lifecycle-") as temp:
        directory = Path(temp)
        test_source = directory / "test.cc"
        test_source.write_text(harness)
        proxy_source = directory / "flutter_common.cc"
        proxy_source.write_text(source(proxy_path))
        binary = directory / "test"
        sanitizers = ["-fsanitize=address,undefined"] if args.sanitize else []
        native_peer = []
        if args.real_peer:
            native_peer = ["-DUSE_REAL_PEER", "-DRTC_DESKTOP_DEVICE",
                           f"-I{plugin / 'third_party/libwebrtc/include'}",
                           str(plugin / "third_party/libwebrtc/lib/libwebrtc.so"),
                           f"-Wl,-rpath,{plugin / 'third_party/libwebrtc/lib'}"]
        command = [os.environ.get("CXX", "c++"), "-std=c++17", "-O0", "-g",
                   "-fno-omit-frame-pointer", *sanitizers,
                   "-ffunction-sections", "-fdata-sections",
                   f"-I{plugin / 'common/cpp/include'}",
                   f"-I{plugin / 'linux/flutter/include'}",
                   f"-I{flutter / 'bin/cache/artifacts/engine' / ('linux-' + arch)}",
                   *gtk_flags, str(test_source), str(proxy_source),
                   str(plugin / "linux/flutter/standard_codec.cc"),
                   *native_peer, "-Wl,--gc-sections", "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
