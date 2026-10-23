#!/usr/bin/env python3
"""Exercise the production Linux binary-messenger wrapper with real GLib refs.

The core Flutter messaging API is replaced with small recording doubles, while
the unmodified wrapper source, Flutter headers and GObject/GBytes/GError lifetime
operations are compiled as used by the plugin. No device or app build is needed.
Use --sanitize for ASan/UBSan and --baseline to reproduce the original ref leak.
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


HARNESS = r'''
#include "binary_messenger_impl.h"

#include <atomic>
#include <cassert>
#include <iostream>
#include <sstream>
#include <thread>
#include <vector>

namespace {
FlBinaryMessengerMessageHandler callback = nullptr;
gpointer callback_data = nullptr;
std::atomic<int> replies{0};
bool fail_response = false;
bool provide_error = true;
int warnings = 0;

void Finalized(gpointer data, GObject*) {
  ++*static_cast<std::atomic<int>*>(data);
}

struct Response {
  Response() {
    handle = reinterpret_cast<FlBinaryMessengerResponseHandle*>(
        g_object_new(G_TYPE_OBJECT, nullptr));
    g_object_weak_ref(G_OBJECT(handle), Finalized, &finalized);
  }
  ~Response() { assert(finalized == 1); }
  std::atomic<int> finalized{0};
  FlBinaryMessengerResponseHandle* handle;
};

void Dispatch(FlBinaryMessenger* messenger, Response& response) {
  g_autoptr(GBytes) message = g_bytes_new_static("request", 7);
  assert(callback);
  callback(messenger, "test", message, response.handle, callback_data);
  // Flutter's caller owns one reference only until its handler returns.
  g_object_unref(response.handle);
  response.handle = nullptr;
}
}  // namespace

// Real GObject instances model messenger/handle ownership without starting an
// engine. These functions implement only the API boundary used by the wrapper.
extern "C" GType fl_binary_messenger_get_type() { return G_TYPE_OBJECT; }
extern "C" GType fl_binary_messenger_response_handle_get_type() {
  return G_TYPE_OBJECT;
}
extern "C" void fl_binary_messenger_set_message_handler_on_channel(
    FlBinaryMessenger*, const gchar*, FlBinaryMessengerMessageHandler handler,
    gpointer user_data, GDestroyNotify) {
  callback = handler;
  callback_data = user_data;
}
extern "C" gboolean fl_binary_messenger_send_response(
    FlBinaryMessenger*, FlBinaryMessengerResponseHandle* handle,
    GBytes* response, GError** error) {
  assert(G_IS_OBJECT(handle));
  assert(response && g_bytes_get_size(response) == 0);
  ++replies;
  if (fail_response && provide_error) {
    g_set_error_literal(error, g_quark_from_static_string("test-error"), 1,
                        "intentional response failure");
  }
  return !fail_response;
}
extern "C" void fl_binary_messenger_send_on_channel(
    FlBinaryMessenger*, const gchar*, GBytes*, GCancellable*,
    GAsyncReadyCallback, gpointer) {
  assert(false && "outgoing messages are outside this harness");
}
extern "C" GBytes* fl_binary_messenger_send_on_channel_finish(
    FlBinaryMessenger*, GAsyncResult*, GError**) {
  assert(false && "outgoing messages are outside this harness");
  return nullptr;
}

// Sanitizers retain the translation unit's unrelated texture vtable too. Fail
// explicitly if a test ever crosses that boundary instead of loading an engine.
extern "C" GType fl_pixel_buffer_texture_get_type() {
  assert(false && "textures are outside this harness");
  return G_TYPE_OBJECT;
}
extern "C" GType fl_texture_get_type() {
  assert(false && "textures are outside this harness");
  return G_TYPE_OBJECT;
}
extern "C" gboolean fl_texture_registrar_register_texture(
    FlTextureRegistrar*, FlTexture*) {
  assert(false && "textures are outside this harness");
  return FALSE;
}
extern "C" gboolean fl_texture_registrar_mark_texture_frame_available(
    FlTextureRegistrar*, FlTexture*) {
  assert(false && "textures are outside this harness");
  return FALSE;
}
extern "C" gboolean fl_texture_registrar_unregister_texture(
    FlTextureRegistrar*, FlTexture*) {
  assert(false && "textures are outside this harness");
  return FALSE;
}

void CheckSynchronous(flutter::BinaryMessengerImpl& wrapper,
                      FlBinaryMessenger* messenger) {
  Response response;
  const int initial = replies;
  wrapper.SetMessageHandler("test", [](const uint8_t*, size_t,
                                       flutter::BinaryReply reply) {
    reply(nullptr, 0);
    auto copy = reply;
    copy(nullptr, 0);  // Copies must share the already-consumed response.
    reply(nullptr, 0);
  });
  Dispatch(messenger, response);
  assert(response.finalized == 1);
  assert(replies == initial + 1);
}

void CheckDeferred(flutter::BinaryMessengerImpl& wrapper,
                   FlBinaryMessenger* messenger, bool respond) {
  Response response;
  const int initial = replies;
  flutter::BinaryReply pending;
  wrapper.SetMessageHandler("test", [&](const uint8_t*, size_t,
                                        flutter::BinaryReply reply) {
    pending = std::move(reply);
  });
  Dispatch(messenger, response);
  assert(response.finalized == 0);
  auto copy = pending;
  pending = nullptr;
  assert(response.finalized == 0);
  if (respond) {
    copy(nullptr, 0);
    // The response should not wait for the callback itself to be destroyed.
    assert(response.finalized == 1);
    copy(nullptr, 0);
  }
  copy = nullptr;
  assert(response.finalized == 1);
  assert(replies == initial + (respond ? 1 : 0));
}

void CheckDropped(flutter::BinaryMessengerImpl& wrapper,
                  FlBinaryMessenger* messenger) {
  Response response;
  const int initial = replies;
  wrapper.SetMessageHandler("test", [](const uint8_t*, size_t,
                                       flutter::BinaryReply) {});
  Dispatch(messenger, response);
  assert(response.finalized == 1);
  assert(replies == initial);
}

void CheckConcurrent(flutter::BinaryMessengerImpl& wrapper,
                     FlBinaryMessenger* messenger) {
  Response response;
  const int initial = replies;
  flutter::BinaryReply pending;
  wrapper.SetMessageHandler("test", [&](const uint8_t*, size_t,
                                        flutter::BinaryReply reply) {
    pending = std::move(reply);
  });
  Dispatch(messenger, response);
  std::vector<std::thread> threads;
  for (int index = 0; index < 8; ++index) {
    threads.emplace_back([copy = pending]() { copy(nullptr, 0); });
  }
  for (auto& thread : threads) thread.join();
  assert(response.finalized == 1);
  assert(replies == initial + 1);
  pending = nullptr;
}

int main() {
  // Expected duplicate replies are diagnostic stderr messages. Swallow them to
  // keep 200 repetitions readable; assertions still fail immediately.
  std::ostringstream duplicate_messages;
  auto* stderr_buffer = std::cerr.rdbuf(duplicate_messages.rdbuf());
  g_log_set_handler(nullptr, G_LOG_LEVEL_WARNING,
      [](const gchar*, GLogLevelFlags, const gchar*, gpointer) { ++warnings; },
      nullptr);
  g_autoptr(GObject) core = G_OBJECT(g_object_new(G_TYPE_OBJECT, nullptr));
  auto* messenger = reinterpret_cast<FlBinaryMessenger*>(core);
  {
    flutter::BinaryMessengerImpl wrapper(messenger);
    for (int iteration = 0; iteration < 200; ++iteration) {
      CheckSynchronous(wrapper, messenger);
      CheckDeferred(wrapper, messenger, true);
      CheckDeferred(wrapper, messenger, false);
      CheckDropped(wrapper, messenger);
      CheckConcurrent(wrapper, messenger);
      fail_response = true;
      CheckSynchronous(wrapper, messenger);
      provide_error = false;
      CheckDeferred(wrapper, messenger, true);
      provide_error = true;
      fail_response = false;
    }
    wrapper.SetMessageHandler("test", nullptr);
  }
  assert(callback == nullptr && callback_data == nullptr);
  assert(replies == 1000);
  assert(warnings == 400);
  std::cerr.rdbuf(stderr_buffer);
  std::cout << "Linux binary messenger: 1400 message lifecycles; all handles "
               "finalized; copied/concurrent replies consumed once; errors freed.\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true",
                        help="exercise HEAD before the local fix (must fail)")
    parser.add_argument("--sanitize", action="store_true",
                        help="enable compiler ASan and UBSan runtimes")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    plugin = Path(__file__).resolve().parents[2]
    root = plugin.parents[1]
    wrapper = plugin / "linux/flutter/core_implementations.cc"
    flutter = Path(shutil.which("flutter")).resolve().parents[1]
    arch = "arm64" if platform.machine() in ("aarch64", "arm64") else "x64"
    gtk_flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "gtk+-3.0"], text=True))
    with tempfile.TemporaryDirectory(prefix="bshare-binary-messenger-") as temp:
        directory = Path(temp)
        test_source = directory / "test.cc"
        test_source.write_text(HARNESS)
        core_source = directory / "core_implementations.cc"
        core_source.write_text(subprocess.check_output(
            ["git", "show", f"HEAD:{wrapper.relative_to(root)}"],
            cwd=root, text=True) if args.baseline else wrapper.read_text())
        binary = directory / "test"
        sanitizers = ["-fsanitize=address,undefined"] if args.sanitize else []
        command = [os.environ.get("CXX", "c++"), "-std=c++17", "-O0", "-g",
                   "-fno-omit-frame-pointer", *sanitizers,
                   "-ffunction-sections", "-fdata-sections",
                   f"-I{plugin / 'linux/flutter'}",
                   f"-I{plugin / 'linux/flutter/include'}",
                   f"-I{flutter / 'bin/cache/artifacts/engine' / ('linux-' + arch)}",
                   str(test_source), str(core_source),
                   *gtk_flags, "-Wl,--gc-sections", "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
