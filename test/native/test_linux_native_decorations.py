#!/usr/bin/env python3
"""Confirm the Linux runner requests normal window-manager decorations."""

from pathlib import Path
import shlex
import subprocess
import tempfile


FIXTURE = r"""
#include <gtk/gtk.h>
#include <cassert>
#include <iostream>

int main(int argc, char** argv) {
  assert(gtk_init_check(&argc, &argv));
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  GtkWindow* window = GTK_WINDOW(widget);
  gtk_window_set_title(window, "BShare native decorations fixture");
  gtk_window_set_decorated(window, TRUE);
  gtk_window_set_resizable(window, TRUE);
  assert(gtk_window_get_decorated(window));
  assert(gtk_window_get_titlebar(window) == nullptr);
  gtk_widget_show(widget);
  while (g_main_context_iteration(nullptr, FALSE)) {}
  gtk_widget_destroy(widget);
  std::cout << "GTK leaves titlebar controls to native window decorations.\n";
}
"""


def main():
    root = Path(__file__).resolve().parents[2]
    source = (root / "linux/runner/my_application.cc").read_text()
    start = source.index("static void my_application_activate(")
    end = source.index("// Implements GApplication::local_command_line.", start)
    activate = source[start:end]
    assert "gtk_window_set_decorated(window, TRUE);" in activate
    assert "gtk_window_set_titlebar" not in source
    assert "gtk_header_bar_new" not in source
    assert "create_window_control_button" not in source

    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "gtk+-3.0"], text=True))
    with tempfile.TemporaryDirectory(prefix="bshare-native-decorations-") as temp:
        test_source = Path(temp) / "test.cc"
        binary = Path(temp) / "test"
        test_source.write_text(FIXTURE)
        subprocess.run([
            "c++", "-std=c++17", "-Wall", "-Werror", str(test_source),
            *flags, "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
