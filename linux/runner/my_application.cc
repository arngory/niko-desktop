#include "my_application.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include <algorithm>
#include <cctype>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Dynamic AppIndicator3 bindings (libayatana-appindicator3 / libappindicator3) so builds never
// require extra dev packages while native Linux trays work automatically when installed.
using AppIndicatorNewFn = gpointer (*)(const gchar*, const gchar*, gint);
using AppIndicatorSetStatusFn = void (*)(gpointer, gint);
using AppIndicatorSetMenuFn = void (*)(gpointer, GtkMenu*);
using AppIndicatorSetTitleFn = void (*)(gpointer, const gchar*);
using AppIndicatorSetIconFullFn = void (*)(gpointer, const gchar*, const gchar*);

struct AppIndicatorApi {
  void* handle = nullptr;
  bool attempted = false;
  bool ready = false;
  AppIndicatorNewFn new_fn = nullptr;
  AppIndicatorSetStatusFn set_status = nullptr;
  AppIndicatorSetMenuFn set_menu = nullptr;
  AppIndicatorSetTitleFn set_title = nullptr;
  AppIndicatorSetIconFullFn set_icon_full = nullptr;

  bool Load() {
    if (attempted) return ready;
    attempted = true;
    handle = dlopen("libayatana-appindicator3.so.1", RTLD_LAZY);
    if (handle == nullptr) {
      handle = dlopen("libappindicator3.so.1", RTLD_LAZY);
    }
    if (handle == nullptr) return false;
    new_fn = reinterpret_cast<AppIndicatorNewFn>(dlsym(handle, "app_indicator_new"));
    set_status = reinterpret_cast<AppIndicatorSetStatusFn>(dlsym(handle, "app_indicator_set_status"));
    set_menu = reinterpret_cast<AppIndicatorSetMenuFn>(dlsym(handle, "app_indicator_set_menu"));
    set_title = reinterpret_cast<AppIndicatorSetTitleFn>(dlsym(handle, "app_indicator_set_title"));
    set_icon_full = reinterpret_cast<AppIndicatorSetIconFullFn>(dlsym(handle, "app_indicator_set_icon_full"));
    ready = (new_fn != nullptr && set_status != nullptr && set_menu != nullptr);
    return ready;
  }
};

constexpr gint kAppIndicatorCategoryApplicationStatus = 0;
constexpr gint kAppIndicatorStatusActive = 1;

const gchar* MapGetString(FlValue* map, const gchar* key, const gchar* fallback) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* val = fl_value_lookup_string(map, key);
  if (val != nullptr && fl_value_get_type(val) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(val);
  }
  return fallback;
}

bool MapGetBool(FlValue* map, const gchar* key, bool fallback) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* val = fl_value_lookup_string(map, key);
  if (val != nullptr && fl_value_get_type(val) == FL_VALUE_TYPE_BOOL) {
    return fl_value_get_bool(val);
  }
  return fallback;
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* window_channel;
  gboolean close_to_tray;
  gboolean quitting;
  gboolean dialog_open;
  AppIndicatorApi tray_api;
  gpointer tray_indicator;
  GtkWidget* tray_menu;
  GtkWidget* tray_status_item;
  GtkWidget* tray_toggle_item;
  GtkWidget* tray_open_item;
  GtkWidget* tray_quit_item;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void emit_tray_action(MyApplication* self, const gchar* action) {
  if (self->window_channel == nullptr) return;
  g_autoptr(FlValue) arg = fl_value_new_string(action);
  fl_method_channel_invoke_method(self->window_channel, "trayAction", arg,
                                  nullptr, nullptr, nullptr);
}

static void tray_toggle_cb(GtkMenuItem* /*item*/, gpointer user_data) {
  emit_tray_action(MY_APPLICATION(user_data), "toggle");
}

static void tray_open_cb(GtkMenuItem* /*item*/, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window != nullptr) {
    gtk_widget_show(GTK_WIDGET(self->window));
    gtk_window_present(self->window);
  }
  emit_tray_action(self, "show");
}

static void tray_quit_cb(GtkMenuItem* /*item*/, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->quitting = TRUE;
  emit_tray_action(self, "quit");
  if (self->window != nullptr) {
    gtk_window_close(self->window);
  }
}

static void ensure_linux_tray(MyApplication* self,
                              bool connected,
                              const gchar* status_label,
                              const gchar* profile_name,
                              const gchar* toggle_label,
                              const gchar* open_label,
                              const gchar* quit_label) {
  if (!self->tray_api.Load()) return;
  if (self->tray_indicator == nullptr) {
    self->tray_menu = gtk_menu_new();
    self->tray_status_item = gtk_menu_item_new_with_label(status_label);
    gtk_widget_set_sensitive(self->tray_status_item, FALSE);
    self->tray_toggle_item = gtk_menu_item_new_with_label(toggle_label);
    self->tray_open_item = gtk_menu_item_new_with_label(open_label);
    self->tray_quit_item = gtk_menu_item_new_with_label(quit_label);

    g_signal_connect(self->tray_toggle_item, "activate", G_CALLBACK(tray_toggle_cb), self);
    g_signal_connect(self->tray_open_item, "activate", G_CALLBACK(tray_open_cb), self);
    g_signal_connect(self->tray_quit_item, "activate", G_CALLBACK(tray_quit_cb), self);

    gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_status_item);
    gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), gtk_separator_menu_item_new());
    gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_toggle_item);
    gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_open_item);
    gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), gtk_separator_menu_item_new());
    gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_quit_item);
    gtk_widget_show_all(self->tray_menu);

    const gchar* icon = connected ? "network-vpn" : "network-offline";
    self->tray_indicator = self->tray_api.new_fn(
        "niko-desktop", icon, kAppIndicatorCategoryApplicationStatus);
    if (self->tray_indicator != nullptr) {
      self->tray_api.set_status(self->tray_indicator, kAppIndicatorStatusActive);
      self->tray_api.set_menu(self->tray_indicator, GTK_MENU(self->tray_menu));
    }
  }
  if (self->tray_indicator != nullptr) {
    std::string header = status_label;
    if (profile_name != nullptr && profile_name[0] != '\0') {
      header += " · ";
      header += profile_name;
    }
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_status_item), header.c_str());
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_toggle_item), toggle_label);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_open_item), open_label);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_quit_item), quit_label);
    if (self->tray_api.set_title != nullptr) {
      self->tray_api.set_title(self->tray_indicator, header.c_str());
    }
    if (self->tray_api.set_icon_full != nullptr) {
      const gchar* icon = connected ? "network-vpn" : "network-offline";
      self->tray_api.set_icon_full(self->tray_indicator, icon, header.c_str());
    }
  }
}

static gboolean window_delete_event_cb(GtkWidget* widget,
                                       GdkEvent* /*event*/,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->close_to_tray && !self->quitting && self->tray_indicator != nullptr) {
    gtk_widget_hide(widget);
    return TRUE;
  }
  return FALSE;
}

// Handles window-level method calls from Dart on the niko/window channel.
static void window_method_call_cb(FlMethodChannel* /*channel*/,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(method, "setDark") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_BOOL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_args", "expected bool", nullptr));
    } else {
      GtkSettings* settings = gtk_settings_get_default();
      if (settings != nullptr) {
        g_object_set(settings, "gtk-application-prefer-dark-theme",
                     fl_value_get_bool(args) ? TRUE : FALSE, nullptr);
      }
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "setCloseToTray") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      self->close_to_tray = fl_value_get_bool(args) ? TRUE : FALSE;
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "showWindow") == 0) {
    if (self->window != nullptr) {
      gtk_widget_show(GTK_WIDGET(self->window));
      gtk_window_present(self->window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "hideWindow") == 0) {
    if (self->window != nullptr) {
      gtk_widget_hide(GTK_WIDGET(self->window));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "closeWindow") == 0) {
    self->quitting = TRUE;
    if (self->window != nullptr) {
      gtk_window_close(self->window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "updateTray") == 0) {
    ensure_linux_tray(
        self,
        MapGetBool(args, "connected", false),
        MapGetString(args, "status", "Niko"),
        MapGetString(args, "profile", ""),
        MapGetString(args, "toggleLabel", "Connect"),
        MapGetString(args, "openLabel", "Open Niko"),
        MapGetString(args, "quitLabel", "Quit"));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "notify") == 0) {
    const gchar* title = MapGetString(args, "title", "Niko");
    const gchar* body = MapGetString(args, "body", "");
    g_autoptr(GNotification) notif = g_notification_new(title);
    if (body[0] != '\0') {
      g_notification_set_body(notif, body);
    }
    g_application_send_notification(G_APPLICATION(self), "niko-status", notif);
    g_autoptr(FlValue) ok = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(ok));
  } else if (g_strcmp0(method, "pickFile") == 0) {
    if (self->dialog_open) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      self->dialog_open = TRUE;
      const gchar* title = MapGetString(args, "title", "Open file");
      GtkFileChooserNative* native = gtk_file_chooser_native_new(
          title, self->window, GTK_FILE_CHOOSER_ACTION_OPEN, "_Open", "_Cancel");
      if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
        FlValue* exts = fl_value_lookup_string(args, "extensions");
        if (exts != nullptr && fl_value_get_type(exts) == FL_VALUE_TYPE_LIST &&
            fl_value_get_length(exts) > 0) {
          GtkFileFilter* filter = gtk_file_filter_new();
          gtk_file_filter_set_name(filter, "Supported files");
          for (size_t i = 0; i < fl_value_get_length(exts); ++i) {
            FlValue* item = fl_value_get_list_value(exts, i);
            if (item != nullptr && fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
              std::string ext = fl_value_get_string(item);
              std::string lower = ext;
              std::string upper = ext;
              std::transform(lower.begin(), lower.end(), lower.begin(),
                             [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
              std::transform(upper.begin(), upper.end(), upper.begin(),
                             [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
              gtk_file_filter_add_pattern(filter, (std::string("*.") + lower).c_str());
              if (upper != lower) {
                gtk_file_filter_add_pattern(filter, (std::string("*.") + upper).c_str());
              }
            }
          }
          gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(native), filter);
          GtkFileFilter* all = gtk_file_filter_new();
          gtk_file_filter_set_name(all, "All files");
          gtk_file_filter_add_pattern(all, "*");
          gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(native), all);
        }
      }
      gint res = gtk_native_dialog_run(GTK_NATIVE_DIALOG(native));
      g_autoptr(FlValue) out = nullptr;
      if (res == GTK_RESPONSE_ACCEPT) {
        g_autofree gchar* filename = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(native));
        if (filename != nullptr) {
          out = fl_value_new_string(filename);
        }
      }
      g_object_unref(native);
      self->dialog_open = FALSE;
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(out));
    }
  } else if (g_strcmp0(method, "pickDirectory") == 0) {
    if (self->dialog_open) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      self->dialog_open = TRUE;
      const gchar* title = MapGetString(args, "title", "Choose folder");
      GtkFileChooserNative* native = gtk_file_chooser_native_new(
          title, self->window, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, "_Select", "_Cancel");
      gint res = gtk_native_dialog_run(GTK_NATIVE_DIALOG(native));
      g_autoptr(FlValue) out = nullptr;
      if (res == GTK_RESPONSE_ACCEPT) {
        g_autofree gchar* folder = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(native));
        if (folder != nullptr) {
          out = fl_value_new_string(folder);
        }
      }
      g_object_unref(native);
      self->dialog_open = FALSE;
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(out));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to %s: %s", method, error->message);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void window_destroy_cb(GtkWidget* widget, MyApplication* self) {
  if (self->window == GTK_WINDOW(widget)) {
    g_clear_object(&self->window_channel);
    self->window = nullptr;
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  if (self->window != nullptr) {
    gtk_widget_show(GTK_WIDGET(self->window));
    gtk_window_present(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_event_cb), self);
  gtk_window_set_default_size(window, 1280, 720);

  GdkGeometry geometry = {};
  geometry.min_width = 420;
  geometry.min_height = 600;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  gtk_window_set_title(window, "Niko");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);
  // Impeller on Linux (OpenGLESSDF) can render only a quarter of the window on
  // Wayland; off by default unless NIKO_IMPELLER=1 is set.
  const gboolean impeller = g_strcmp0(g_getenv("NIKO_IMPELLER"), "1") == 0;
  fl_dart_project_set_enable_impeller(project, impeller);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  gboolean wayland = FALSE;
#ifdef GDK_WINDOWING_WAYLAND
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  wayland = display != nullptr && GDK_IS_WAYLAND_DISPLAY(display);
#endif
  g_debug("niko: display=%s scale=%d impeller=%d",
          wayland ? "wayland" : "x11-or-other",
          gtk_widget_get_scale_factor(GTK_WIDGET(window)), impeller ? 1 : 0);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->window_channel);
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "niko/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
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

static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->window_channel);
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
  self->close_to_tray = FALSE;
  self->quitting = FALSE;
  self->tray_indicator = nullptr;
  self->tray_menu = nullptr;
}

#ifndef NDEBUG
#define NIKO_APPLICATION_ID APPLICATION_ID ".debug"
#else
#define NIKO_APPLICATION_ID APPLICATION_ID
#endif

MyApplication* my_application_new() {
  g_set_prgname(NIKO_APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", NIKO_APPLICATION_ID,
                                     "flags", G_APPLICATION_DEFAULT_FLAGS,
                                     nullptr));
}
