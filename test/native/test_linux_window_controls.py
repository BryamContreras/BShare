#!/usr/bin/env python3
"""Exercise the production GTK title controls with broken decoration assets.

The runner helpers are copied unchanged into a GTK/Cairo fixture, without
building Flutter. A process-local stylesheet models KDE decoration SVGs with no
geometry and transparent title-button images. The fixture inspects accessibility,
renders the real drawing callbacks, and checks the normal delete-event path.
It needs a GTK3 display; it does not change desktop or theme preferences.
"""

from pathlib import Path
import argparse
import os
import resource
import shlex
import subprocess
import tempfile

from test_linux_window_shutdown import production_definition


HARNESS = r'''
#include <gtk/gtk.h>
#include <atk/atk.h>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

// WINDOW_CONTROL
// DRAW_CONTROL
// CLICKED_CONTROL
// MAXIMIZE_STATE
// WINDOW_STATE_EVENT
// CREATE_CONTROL
// SET_CONTROLS

void DrainEvents() {
  while (g_main_context_iteration(nullptr, FALSE)) {}
}

void CollectButtons(GtkWidget* widget, std::vector<GtkWidget*>& result) {
  if (GTK_IS_BUTTON(widget)) result.push_back(widget);
  if (!GTK_IS_CONTAINER(widget)) return;
  GList* children = gtk_container_get_children(GTK_CONTAINER(widget));
  for (GList* child = children; child != nullptr; child = child->next) {
    CollectButtons(GTK_WIDGET(child->data), result);
  }
  g_list_free(children);
}

std::string AccessibleName(GtkWidget* widget) {
  const char* name = atk_object_get_name(gtk_widget_get_accessible(widget));
  return name == nullptr ? std::string() : std::string(name);
}

std::string Tooltip(GtkWidget* widget) {
  g_autofree char* tooltip = gtk_widget_get_tooltip_text(widget);
  return tooltip == nullptr ? std::string() : std::string(tooltip);
}

std::vector<unsigned char> RenderIcon(GtkWidget* button) {
  GtkWidget* drawing = gtk_bin_get_child(GTK_BIN(button));
  assert(GTK_IS_DRAWING_AREA(drawing));
  GtkAllocation allocation{0, 0, 20, 20};
  gtk_widget_size_allocate(drawing, &allocation);
  cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                       20, 20);
  cairo_t* context = cairo_create(surface);
  cairo_set_operator(context, CAIRO_OPERATOR_CLEAR);
  cairo_paint(context);
  cairo_set_operator(context, CAIRO_OPERATOR_OVER);
  cairo_set_line_width(context, 3.25);
  cairo_set_line_cap(context, CAIRO_LINE_CAP_SQUARE);
  cairo_set_source_rgba(context, 0.2, 0.3, 0.4, 0.5);
  cairo_matrix_t matrix_before;
  cairo_get_matrix(context, &matrix_before);
  cairo_pattern_t* source_before = cairo_pattern_reference(
      cairo_get_source(context));
  gboolean handled = FALSE;
  g_signal_emit_by_name(drawing, "draw", context, &handled);
  assert(!handled);
  cairo_matrix_t matrix_after;
  cairo_get_matrix(context, &matrix_after);
  assert(matrix_after.xx == matrix_before.xx);
  assert(matrix_after.xy == matrix_before.xy);
  assert(matrix_after.yx == matrix_before.yx);
  assert(matrix_after.yy == matrix_before.yy);
  assert(matrix_after.x0 == matrix_before.x0);
  assert(matrix_after.y0 == matrix_before.y0);
  assert(cairo_get_line_width(context) == 3.25);
  assert(cairo_get_line_cap(context) == CAIRO_LINE_CAP_SQUARE);
  assert(cairo_get_source(context) == source_before);
  cairo_pattern_destroy(source_before);
  cairo_destroy(context);
  cairo_surface_flush(surface);
  assert(cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS);
  const auto* pixels = cairo_image_surface_get_data(surface);
  const int stride = cairo_image_surface_get_stride(surface);
  std::vector<unsigned char> result(pixels, pixels + stride * 20);
  int visible_pixels = 0;
  for (int y = 0; y < 20; ++y) {
    const auto* row = reinterpret_cast<const std::uint32_t*>(pixels + y * stride);
    for (int x = 0; x < 20; ++x) {
      if ((row[x] >> 24) > 32) ++visible_pixels;
    }
  }
  assert(visible_pixels >= 8);
  assert(visible_pixels < 250);
  cairo_surface_destroy(surface);
  return result;
}

int main(int argc, char** argv) {
  if (!gtk_init_check(&argc, &argv)) {
    std::cerr << "GTK3 display unavailable; use a display or xvfb-run.\n";
    return 77;
  }
  assert(argc == 2);
  g_autoptr(GtkCssProvider) provider = gtk_css_provider_new();
  g_autoptr(GError) error = nullptr;
  assert(gtk_css_provider_load_from_path(provider, argv[1], &error));
  gtk_style_context_add_provider_for_screen(
      gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_USER + 1);

  GtkWidget* window_widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  auto* window = GTK_WINDOW(window_widget);
  gtk_window_set_title(window, "BShare controls fixture");
  gtk_window_set_default_size(window, 300, 150);
  GtkWidget* header_widget = gtk_header_bar_new();
  auto* header = GTK_HEADER_BAR(header_widget);
  gtk_header_bar_set_title(header, "Controls fixture");
  set_window_controls(header, window);
  gtk_window_set_titlebar(window, header_widget);
  gtk_widget_show_all(header_widget);

  assert(!gtk_header_bar_get_show_close_button(header));
  std::vector<GtkWidget*> buttons;
  CollectButtons(header_widget, buttons);
  assert(buttons.size() == 3);
  GtkWidget* minimize = nullptr;
  GtkWidget* maximize = nullptr;
  GtkWidget* close = nullptr;
  for (GtkWidget* button : buttons) {
    auto* context = gtk_widget_get_style_context(button);
    assert(gtk_style_context_has_class(context, "bshare-window-control"));
    for (const char* forbidden : {"titlebutton", "close", "maximize", "minimize"}) {
      assert(!gtk_style_context_has_class(context, forbidden));
    }
    int minimum_width = 0;
    int minimum_height = 0;
    gtk_widget_get_size_request(button, &minimum_width, &minimum_height);
    assert(minimum_width >= 32 && minimum_height >= 32);
    assert(gtk_widget_get_can_focus(button));
    const std::string name = gtk_widget_get_name(button);
    if (name == "bshare-window-minimize") minimize = button;
    if (name == "bshare-window-maximize") maximize = button;
    if (name == "bshare-window-close") close = button;
    assert(atk_object_get_role(gtk_widget_get_accessible(button)) ==
           ATK_ROLE_PUSH_BUTTON);
  }
  assert(minimize && maximize && close);
  assert(AccessibleName(minimize) == "Minimize");
  assert(AccessibleName(maximize) == "Maximize");
  assert(AccessibleName(close) == "Close");
  assert(Tooltip(minimize) == "Minimize");
  assert(Tooltip(maximize) == "Maximize");
  assert(Tooltip(close) == "Close");

  // No fixture window is shown: icon rendering uses an image surface directly.
  const auto minimize_pixels = RenderIcon(minimize);
  const auto maximize_pixels = RenderIcon(maximize);
  const auto close_pixels = RenderIcon(close);
  assert(minimize_pixels != maximize_pixels);
  assert(maximize_pixels != close_pixels);
  assert(minimize_pixels != close_pixels);

  GdkEventWindowState state{};
  state.type = GDK_WINDOW_STATE;
  state.changed_mask = GDK_WINDOW_STATE_MAXIMIZED;
  state.new_window_state = GDK_WINDOW_STATE_MAXIMIZED;
  window_state_event_cb(window, &state, maximize);
  assert(AccessibleName(maximize) == "Restore");
  assert(Tooltip(maximize) == "Restore");
  assert(RenderIcon(maximize) != maximize_pixels);
  state.changed_mask = GDK_WINDOW_STATE_ICONIFIED;
  state.new_window_state = static_cast<GdkWindowState>(0);
  window_state_event_cb(window, &state, maximize);
  assert(AccessibleName(maximize) == "Restore");
  state.changed_mask = GDK_WINDOW_STATE_MAXIMIZED;
  state.new_window_state = static_cast<GdkWindowState>(0);
  window_state_event_cb(window, &state, maximize);
  assert(AccessibleName(maximize) == "Maximize");
  assert(Tooltip(maximize) == "Maximize");
  assert(RenderIcon(maximize) == maximize_pixels);

  // Realizing creates only this fixture's native surface. Close must dispatch
  // delete-event so the Flutter runner can await its existing shutdown path.
  int delete_requests = 0;
  bool destroyed = false;
  g_signal_connect(window, "delete-event", G_CALLBACK(+[](
      GtkWidget*, GdkEvent*, gpointer data) -> gboolean {
    ++*static_cast<int*>(data);
    return TRUE;
  }), &delete_requests);
  g_signal_connect(window, "destroy", G_CALLBACK(+[](
      GtkWidget*, gpointer data) {
    *static_cast<bool*>(data) = true;
  }), &destroyed);
  gtk_widget_realize(window_widget);
  gtk_button_clicked(GTK_BUTTON(close));
  DrainEvents();
  assert(delete_requests == 1);
  assert(!destroyed);
  // A second request remains safe when the first close was declined.
  gtk_button_clicked(GTK_BUTTON(close));
  DrainEvents();
  assert(delete_requests == 2);
  assert(!destroyed);
  gtk_widget_destroy(window_widget);
  DrainEvents();
  assert(destroyed);
  gtk_style_context_remove_provider_for_screen(
      gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider));
  std::cout << "Linux title controls: 3 accessible buttons; Cairo minimize, "
               "maximize, restore and close glyphs remain visible with empty "
               "decoration SVGs; state labels update; close dispatches "
               "delete-event without bypassing its handler.\n";
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
        ("WINDOW_CONTROL", "enum WindowControl", True),
        ("DRAW_CONTROL", "static gboolean draw_window_control(", False),
        ("CLICKED_CONTROL", "static void window_control_clicked_cb(", False),
        ("MAXIMIZE_STATE", "static void set_maximize_button_state(", False),
        ("WINDOW_STATE_EVENT", "static gboolean window_state_event_cb(", False),
        ("CREATE_CONTROL", "static GtkWidget* create_window_control_button(", False),
        ("SET_CONTROLS", "static void set_window_controls(", False),
    ]:
        harness = harness.replace("// " + marker,
                                  production_definition(source, signature,
                                                        semicolon))
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "gtk+-3.0"], text=True))
    with tempfile.TemporaryDirectory(prefix="bshare-linux-controls-") as temp:
        directory = Path(temp)
        test_source = directory / "test.cc"
        test_source.write_text(harness)
        binary = directory / "test"
        sanitizers = ["-fsanitize=address,undefined"] if args.sanitize else []
        subprocess.run([
            os.environ.get("CXX", "c++"), "-std=c++14", "-O0", "-g",
            "-Wall", "-Werror", "-fno-omit-frame-pointer", *sanitizers,
            str(test_source), *flags, "-o", str(binary),
        ], check=True)
        (directory / "empty.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50">'
            '<g fill="none"/></svg>')
        stylesheet = directory / "broken-decoration.css"
        stylesheet.write_text('''
headerbar button, .titlebar button {
  background-image: url("empty.svg");
}
headerbar button image, .titlebar button image {
  color: transparent;
}
''')
        environment = os.environ.copy()
        environment.update({"LC_ALL": "C", "LANGUAGE": "C"})
        subprocess.run([str(binary), str(stylesheet)], check=True,
                       env=environment, timeout=20)


if __name__ == "__main__":
    main()
