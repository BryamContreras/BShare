#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GPtrArray* owned_windows;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

struct OwnedWindow {
  GtkWindow* window;
  GWeakRef engine;
};

struct EngineShutdownState {
  GMainContext* context;
  gint pending;
};

static void owned_window_free(gpointer data) {
  OwnedWindow* owned = static_cast<OwnedWindow*>(data);
  gtk_widget_destroy(GTK_WIDGET(owned->window));
  g_clear_object(&owned->window);
  g_weak_ref_clear(&owned->engine);
  g_free(owned);
}

static void engine_finalized_cb(gpointer data, GObject*) {
  EngineShutdownState* state = static_cast<EngineShutdownState*>(data);
  // The last reference can be released by an engine thread. Keep the context
  // alive independently before making the final update to the stack state.
  GMainContext* context = g_main_context_ref(state->context);
  g_atomic_int_add(&state->pending, -1);
  g_main_context_wakeup(context);
  g_main_context_unref(context);
}

static void shutdown_owned_windows(MyApplication* self) {
  if (self->owned_windows == nullptr) return;

  EngineShutdownState state = {g_main_context_ref_thread_default(), 0};
  for (guint index = 0; index < self->owned_windows->len; ++index) {
    OwnedWindow* owned = static_cast<OwnedWindow*>(
        g_ptr_array_index(self->owned_windows, index));
    g_autoptr(GObject) engine =
        static_cast<GObject*>(g_weak_ref_get(&owned->engine));
    if (engine != nullptr) {
      g_atomic_int_inc(&state.pending);
      g_object_weak_ref(engine, engine_finalized_cb, &state);
    }
  }

  // Flutter's exit handler detaches windows from GtkApplication before quitting.
  // Keep our own list so their FlView and engine are still destroyed explicitly.
  g_clear_pointer(&self->owned_windows, g_ptr_array_unref);

  // FlView disposal schedules RemoveView through a GTask that retains its
  // engine. Continue dispatching completions until engine disposal has stopped
  // the raster thread, including callbacks that have not been posted yet.
  while (g_atomic_int_get(&state.pending) > 0) {
    g_main_context_iteration(state.context, TRUE);
  }
  g_main_context_unref(state.context);
}

static gchar* get_app_icon_path() {
  g_autofree gchar* executable_path = g_file_read_link("/proc/self/exe", nullptr);
  if (executable_path == nullptr) return nullptr;

  g_autofree gchar* executable_dir = g_path_get_dirname(executable_path);
  return g_build_filename(executable_dir, "data", "flutter_assets", "assets",
                          "brand", "app_icon.png", nullptr);
}

static void set_default_app_icon() {
  gtk_window_set_default_icon_name(APPLICATION_ID);

  g_autofree gchar* icon_path = get_app_icon_path();
  if (icon_path == nullptr || !g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    return;
  }

  g_autoptr(GError) error = nullptr;
  if (!gtk_window_set_default_icon_from_file(icon_path, &error)) {
    g_warning("Failed to load default app icon: %s", error->message);
  }
}

static void set_app_window_icon(GtkWindow* window) {
  gtk_window_set_icon_name(window, APPLICATION_ID);

  g_autofree gchar* icon_path = get_app_icon_path();
  if (icon_path == nullptr || !g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    return;
  }

  g_autoptr(GError) error = nullptr;
  if (!gtk_window_set_icon_from_file(window, icon_path, &error)) {
    g_warning("Failed to load app icon: %s", error->message);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  set_app_window_icon(window);
  gtk_window_set_title(window, "BShare");
  gtk_window_set_decorated(window, TRUE);
  gtk_window_set_deletable(window, TRUE);
  gtk_window_set_resizable(window, TRUE);

  // Let GTK and the active window manager provide the native title bar and
  // its minimize, maximize and close controls. Leave a custom titlebar unset.

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  OwnedWindow* owned = g_new0(OwnedWindow, 1);
  owned->window = GTK_WINDOW(g_object_ref(window));
  g_weak_ref_init(&owned->engine, G_OBJECT(fl_view_get_engine(view)));
  g_ptr_array_add(self->owned_windows, owned);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  set_default_app_icon();
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  shutdown_owned_windows(MY_APPLICATION(application));
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  shutdown_owned_windows(self);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->owned_windows = g_ptr_array_new_with_free_func(owned_window_free);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_application_name("BShare");
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
