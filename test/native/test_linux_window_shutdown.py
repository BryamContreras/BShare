#!/usr/bin/env python3
"""Check the production Linux runner's window and engine shutdown ownership.

Runner helpers are copied unchanged into a GLib/GObject fixture. Window doubles
model Flutter detaching GtkWindows and FlView retaining its engine through an
asynchronous RemoveView GTask. No display, Flutter build or device is needed.
"""

from pathlib import Path
import argparse
import os
import resource
import shlex
import subprocess
import tempfile


def production_definition(source, signature, semicolon=False):
    start = source.index(signature)
    cursor = source.index("{", start)
    depth = 1
    end = cursor + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end + (1 if semicolon else 0)]


HARNESS = r'''
#include <gio/gio.h>
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

// A display-free window double owns its engine until widget destruction.
using GtkWindow = GObject;
#define GTK_WIDGET(object) (object)
struct MyApplication { GPtrArray* owned_windows; };

std::vector<std::thread> workers;
int destroyed_windows = 0;
int finalized_windows = 0;
int finalized_engines = 0;

void WindowFinalized(gpointer, GObject*) { ++finalized_windows; }
void EngineFinalized(gpointer, GObject*) { ++finalized_engines; }

void gtk_widget_destroy(GObject* window) {
  if (g_object_get_data(window, "destroyed")) return;
  g_object_set_data(window, "destroyed", GINT_TO_POINTER(1));
  ++destroyed_windows;
  auto* engine = static_cast<GObject*>(g_object_get_data(window, "engine"));
  if (engine) {
    const int mode = GPOINTER_TO_INT(g_object_get_data(window, "delay"));
    if (mode == 1) {
      // This callback is not pending when shutdown checks the context: the
      // runner must wait for future completions, not just drain ready sources.
      GTask* task = g_task_new(engine, nullptr, nullptr, nullptr);
      g_timeout_add(10, [](gpointer data) -> gboolean {
        auto* task = G_TASK(data);
        g_task_return_boolean(task, TRUE);
        g_object_unref(task);
        return G_SOURCE_REMOVE;
      }, task);
    } else if (mode == 2) {
      g_object_ref(engine);
      workers.emplace_back([engine]() {
        g_usleep(10000);
        g_object_unref(engine);
      });
    }
    g_object_set_data(window, "engine", nullptr);
  }
}

// OWNED_WINDOW
// SHUTDOWN_STATE
// WINDOW_FREE
// ENGINE_FINALIZED
// SHUTDOWN_WINDOWS

GObject* AddWindow(MyApplication& app, int delay) {
  auto* window = G_OBJECT(g_object_new(G_TYPE_OBJECT, nullptr));
  auto* engine = G_OBJECT(g_object_new(G_TYPE_OBJECT, nullptr));
  g_object_weak_ref(window, WindowFinalized, nullptr);
  g_object_weak_ref(engine, EngineFinalized, nullptr);
  g_object_set_data_full(window, "engine", engine, g_object_unref);
  g_object_set_data(window, "delay", GINT_TO_POINTER(delay));
  auto* owned = g_new0(OwnedWindow, 1);
  owned->window = window;
  g_weak_ref_init(&owned->engine, engine);
  g_ptr_array_add(app.owned_windows, owned);
  return window;
}

int main() {
  // An unrelated window must stay alive and remain untouched.
  g_autoptr(GObject) unrelated = G_OBJECT(g_object_new(G_TYPE_OBJECT, nullptr));
  for (int iteration = 0; iteration < 100; ++iteration) {
    MyApplication app{g_ptr_array_new_with_free_func(owned_window_free)};
    const int windows_before = destroyed_windows;
    const int engines_before = finalized_engines;
    AddWindow(app, 0);                 // Synchronous engine disposal.
    AddWindow(app, 1);                 // Delayed RemoveView GTask.
    AddWindow(app, 2);                 // Final ref released off the main thread.
    gtk_widget_destroy(AddWindow(app, 1));  // Already detached/destroyed window.
    gtk_widget_destroy(AddWindow(app, 0));  // Engine already gone at shutdown.
    const gint64 start = g_get_monotonic_time();
    shutdown_owned_windows(&app);
    const gint64 duration = g_get_monotonic_time() - start;
    assert(duration >= 5000);          // Waited for not-yet-ready callbacks.
    assert(app.owned_windows == nullptr);
    assert(destroyed_windows == windows_before + 5);
    assert(finalized_engines == engines_before + 5);
    assert(finalized_windows == (iteration + 1) * 5);
    assert(!g_object_get_data(unrelated, "destroyed"));
    shutdown_owned_windows(&app);      // GObject dispose after shutdown is safe.
    for (auto& worker : workers) worker.join();
    workers.clear();
  }
  MyApplication empty{g_ptr_array_new_with_free_func(owned_window_free)};
  shutdown_owned_windows(&empty);
  shutdown_owned_windows(&empty);
  std::cout << "Linux runner shutdown: 500 owned windows and engines finalized; "
               "delayed GTask/thread releases awaited; unrelated window intact; "
               "repeat cleanup safe.\n";
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", action="store_true",
                        help="enable ASan and UBSan runtimes")
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    root = Path(__file__).resolve().parents[2]
    source = (root / "linux/runner/my_application.cc").read_text()
    harness = HARNESS
    for marker, signature, semicolon in [
        ("OWNED_WINDOW", "struct OwnedWindow", True),
        ("SHUTDOWN_STATE", "struct EngineShutdownState", True),
        ("WINDOW_FREE", "static void owned_window_free(", False),
        ("ENGINE_FINALIZED", "static void engine_finalized_cb(", False),
        ("SHUTDOWN_WINDOWS", "static void shutdown_owned_windows(", False),
    ]:
        harness = harness.replace("// " + marker,
                                  production_definition(source, signature,
                                                        semicolon))
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "gio-2.0", "gobject-2.0"],
        text=True))
    with tempfile.TemporaryDirectory(prefix="bshare-linux-shutdown-") as temp:
        directory = Path(temp)
        test_source = directory / "test.cc"
        test_source.write_text(harness)
        binary = directory / "test"
        sanitizers = ["-fsanitize=address,undefined"] if args.sanitize else []
        command = [os.environ.get("CXX", "c++"), "-std=c++14", "-O0", "-g",
                   "-Wall", "-Werror", "-fno-omit-frame-pointer", *sanitizers,
                   str(test_source), *flags, "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
