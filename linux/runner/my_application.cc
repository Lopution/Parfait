#include "my_application.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>

#include <cstring>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include "flutter/generated_plugin_registrant.h"

namespace {

typedef void* AppIndicatorPtr;
constexpr gint kAppIndicatorCategoryApplicationStatus = 0;
constexpr gint kAppIndicatorStatusPassive = 0;
constexpr gint kAppIndicatorStatusActive = 1;

using FnAppIndicatorNew = AppIndicatorPtr (*)(const gchar* id,
                                              const gchar* icon_name,
                                              gint category);
using FnAppIndicatorSetStatus = void (*)(AppIndicatorPtr indicator,
                                         gint status);
using FnAppIndicatorSetMenu = void (*)(AppIndicatorPtr indicator,
                                       GtkMenu* menu);
using FnAppIndicatorSetTitle = void (*)(AppIndicatorPtr indicator,
                                        const gchar* title);

struct AppIndicatorApi {
  bool attempted = false;
  bool available = false;
  void* dl_handle = nullptr;
  FnAppIndicatorNew indicator_new = nullptr;
  FnAppIndicatorSetStatus set_status = nullptr;
  FnAppIndicatorSetMenu set_menu = nullptr;
  FnAppIndicatorSetTitle set_title = nullptr;
};

AppIndicatorApi g_app_indicator;

template <typename Fn>
Fn LoadDlSymbol(void* handle, const char* name) {
  void* raw = dlsym(handle, name);
  Fn fn = nullptr;
  if (raw != nullptr) {
    std::memcpy(&fn, &raw, sizeof(fn));
  }
  return fn;
}

bool EnsureAppIndicatorLoaded() {
  if (g_app_indicator.attempted) {
    return g_app_indicator.available;
  }
  g_app_indicator.attempted = true;

  const char* candidates[] = {
      "libayatana-appindicator3.so.1",
      "libappindicator3.so.1",
  };
  for (const char* lib : candidates) {
    void* handle = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
      continue;
    }
    auto fn_new = LoadDlSymbol<FnAppIndicatorNew>(handle, "app_indicator_new");
    auto fn_set_status =
        LoadDlSymbol<FnAppIndicatorSetStatus>(handle, "app_indicator_set_status");
    auto fn_set_menu =
        LoadDlSymbol<FnAppIndicatorSetMenu>(handle, "app_indicator_set_menu");
    if (fn_new != nullptr && fn_set_status != nullptr &&
        fn_set_menu != nullptr) {
      g_app_indicator.dl_handle = handle;
      g_app_indicator.indicator_new = fn_new;
      g_app_indicator.set_status = fn_set_status;
      g_app_indicator.set_menu = fn_set_menu;
      g_app_indicator.set_title =
          LoadDlSymbol<FnAppIndicatorSetTitle>(handle, "app_indicator_set_title");
      g_app_indicator.available = true;
      return true;
    }
    dlclose(handle);
  }
  return false;
}

bool IsSupportedLaunchUri(const gchar* arg) {
  if (arg == nullptr) {
    return false;
  }
  return g_ascii_strncasecmp(arg, "pixiv://", 8) == 0 ||
         g_ascii_strncasecmp(arg, "parfait://", 10) == 0 ||
         g_ascii_strncasecmp(arg, "http://", 7) == 0 ||
         g_ascii_strncasecmp(arg, "https://", 8) == 0;
}

const gchar* ExtractSupportedUriFromStrv(gchar* const* args) {
  if (args == nullptr) {
    return nullptr;
  }
  for (int i = 0; args[i] != nullptr; ++i) {
    if (IsSupportedLaunchUri(args[i])) {
      return args[i];
    }
  }
  return nullptr;
}

FlValue* BuildViewIntentPayload(const gchar* uri) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "action",
                           fl_value_new_string("android.intent.action.VIEW"));
  fl_value_set_string_take(map, "uri", fl_value_new_string(uri));
  return map;
}

const gchar* ReadMapString(FlValue* map, const gchar* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(map, key);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(value);
  }
  return nullptr;
}

const gchar* ResolveTrayIconName() {
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  if (theme != nullptr) {
    if (gtk_icon_theme_has_icon(theme, APPLICATION_ID)) {
      return APPLICATION_ID;
    }
    if (gtk_icon_theme_has_icon(theme, "parfait")) {
      return "parfait";
    }
  }
  return "applications-internet";
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  GtkWindow* main_window;
  gboolean is_wayland;
  gboolean is_fullscreen;
  gboolean is_maximized;
  gboolean is_active;

  gchar* initial_intent_uri;
  gboolean initial_intent_consumed;
  gboolean intent_listening;
  GPtrArray* pending_live_uris;

  FlMethodChannel* desktop_window_channel;
  FlMethodChannel* tray_channel;
  FlMethodChannel* intent_channel;
  FlEventChannel* intent_event_channel;

  AppIndicatorPtr tray_indicator;
  GtkMenu* tray_menu;
  GtkWidget* tray_show_item;
  GtkWidget* tray_downloads_item;
  GtkWidget* tray_quit_item;
  gchar* tray_tooltip;
  gchar* tray_show_label;
  gchar* tray_downloads_label;
  gchar* tray_quit_label;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean DetectWaylandSession(GtkWindow* window) {
#ifdef GDK_WINDOWING_WAYLAND
  if (window != nullptr) {
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
    if (display != nullptr && GDK_IS_WAYLAND_DISPLAY(display)) {
      return TRUE;
    }
  }
#endif
  const gchar* session_type = g_getenv("XDG_SESSION_TYPE");
  if (session_type != nullptr &&
      g_ascii_strcasecmp(session_type, "wayland") == 0) {
    return TRUE;
  }
  const gchar* wayland_display = g_getenv("WAYLAND_DISPLAY");
  return wayland_display != nullptr && wayland_display[0] != '\0';
}

static FlValue* BuildWindowMetricsMap(MyApplication* self) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "isWayland",
                           fl_value_new_bool(self->is_wayland != FALSE));
  // Native GTK HeaderBar (Wayland / GNOME Shell) or WM frame (X11) draws the
  // window controls cleanly; Flutter hides duplicate controls.
  fl_value_set_string_take(map, "usesSystemTitleBar", fl_value_new_bool(true));
  fl_value_set_string_take(map, "isFullScreen",
                           fl_value_new_bool(self->is_fullscreen != FALSE));
  fl_value_set_string_take(map, "isMaximized",
                           fl_value_new_bool(self->is_maximized != FALSE));
  fl_value_set_string_take(map, "isActive",
                           fl_value_new_bool(self->is_active != FALSE));
  fl_value_set_string_take(map, "trafficLightWidth", fl_value_new_float(0.0));
  fl_value_set_string_take(map, "trafficLightHeight", fl_value_new_float(0.0));
  fl_value_set_string_take(map, "hoveredButton", fl_value_new_string(""));
  fl_value_set_string_take(map, "pressedButton", fl_value_new_string(""));
  return map;
}

static void EmitWindowMetrics(MyApplication* self) {
  if (self->desktop_window_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) metrics = BuildWindowMetricsMap(self);
  fl_method_channel_invoke_method(self->desktop_window_channel,
                                  "metricsChanged", metrics, nullptr, nullptr,
                                  nullptr);
}

static void RestoreAndPresentWindow(MyApplication* self) {
  if (self->main_window == nullptr) {
    return;
  }
  gtk_widget_show(GTK_WIDGET(self->main_window));
  gtk_window_deiconify(self->main_window);
  gtk_window_present(self->main_window);
}

static void DeliverExternalUri(MyApplication* self, const gchar* uri) {
  if (uri == nullptr || !IsSupportedLaunchUri(uri)) {
    return;
  }
  if (self->intent_event_channel != nullptr && self->intent_listening) {
    g_autoptr(FlValue) payload = BuildViewIntentPayload(uri);
    g_autoptr(GError) error = nullptr;
    if (!fl_event_channel_send(self->intent_event_channel, payload, nullptr,
                               &error)) {
      g_warning("Failed to emit intent event: %s",
                error != nullptr ? error->message : "unknown");
    }
    return;
  }
  if (self->initial_intent_consumed) {
    if (self->pending_live_uris == nullptr) {
      self->pending_live_uris = g_ptr_array_new_with_free_func(g_free);
    }
    g_ptr_array_add(self->pending_live_uris, g_strdup(uri));
    return;
  }
  g_free(self->initial_intent_uri);
  self->initial_intent_uri = g_strdup(uri);
}

static void SendTrayAction(MyApplication* self, const gchar* action) {
  if (self->tray_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) arg = fl_value_new_string(action);
  fl_method_channel_invoke_method(self->tray_channel, "onTrayAction", arg,
                                  nullptr, nullptr, nullptr);
}

static void on_tray_show_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  RestoreAndPresentWindow(self);
  SendTrayAction(self, "showWindow");
}

static void on_tray_downloads_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  RestoreAndPresentWindow(self);
  SendTrayAction(self, "openDownloads");
}

static void on_tray_quit_activate(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  SendTrayAction(self, "quit");
}

static void UpdateTrayLabelsFromArgs(MyApplication* self, FlValue* args) {
  const gchar* tooltip = ReadMapString(args, "tooltip");
  const gchar* show = ReadMapString(args, "showWindow");
  const gchar* downloads = ReadMapString(args, "downloads");
  const gchar* quit = ReadMapString(args, "quit");

  if (tooltip != nullptr && tooltip[0] != '\0') {
    g_free(self->tray_tooltip);
    self->tray_tooltip = g_strdup(tooltip);
  }
  if (show != nullptr && show[0] != '\0') {
    g_free(self->tray_show_label);
    self->tray_show_label = g_strdup(show);
  }
  if (downloads != nullptr && downloads[0] != '\0') {
    g_free(self->tray_downloads_label);
    self->tray_downloads_label = g_strdup(downloads);
  }
  if (quit != nullptr && quit[0] != '\0') {
    g_free(self->tray_quit_label);
    self->tray_quit_label = g_strdup(quit);
  }

  if (self->tray_show_item != nullptr && self->tray_show_label != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_show_item),
                            self->tray_show_label);
  }
  if (self->tray_downloads_item != nullptr &&
      self->tray_downloads_label != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_downloads_item),
                            self->tray_downloads_label);
  }
  if (self->tray_quit_item != nullptr && self->tray_quit_label != nullptr) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->tray_quit_item),
                            self->tray_quit_label);
  }
  if (self->tray_indicator != nullptr && g_app_indicator.set_title != nullptr &&
      self->tray_tooltip != nullptr) {
    g_app_indicator.set_title(self->tray_indicator, self->tray_tooltip);
  }
}

static void EnsureTrayInitialized(MyApplication* self) {
  if (!EnsureAppIndicatorLoaded()) {
    return;
  }
  if (self->tray_indicator != nullptr) {
    return;
  }

  GtkWidget* menu_widget = gtk_menu_new();
  self->tray_menu = GTK_MENU(g_object_ref_sink(menu_widget));

  self->tray_show_item = gtk_menu_item_new_with_label(
      self->tray_show_label != nullptr ? self->tray_show_label : "Show Window");
  g_signal_connect(self->tray_show_item, "activate",
                   G_CALLBACK(on_tray_show_activate), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_show_item);

  self->tray_downloads_item = gtk_menu_item_new_with_label(
      self->tray_downloads_label != nullptr ? self->tray_downloads_label
                                            : "Downloads");
  g_signal_connect(self->tray_downloads_item, "activate",
                   G_CALLBACK(on_tray_downloads_activate), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                        self->tray_downloads_item);

  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                        gtk_separator_menu_item_new());

  self->tray_quit_item = gtk_menu_item_new_with_label(
      self->tray_quit_label != nullptr ? self->tray_quit_label : "Quit");
  g_signal_connect(self->tray_quit_item, "activate",
                   G_CALLBACK(on_tray_quit_activate), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->tray_quit_item);

  gtk_widget_show_all(GTK_WIDGET(self->tray_menu));

  self->tray_indicator = g_app_indicator.indicator_new(
      APPLICATION_ID, ResolveTrayIconName(),
      kAppIndicatorCategoryApplicationStatus);
  if (self->tray_indicator == nullptr) {
    g_clear_object(&self->tray_menu);
    self->tray_show_item = nullptr;
    self->tray_downloads_item = nullptr;
    self->tray_quit_item = nullptr;
    return;
  }
  g_app_indicator.set_menu(self->tray_indicator, self->tray_menu);
  g_app_indicator.set_status(self->tray_indicator, kAppIndicatorStatusActive);
  if (g_app_indicator.set_title != nullptr && self->tray_tooltip != nullptr) {
    g_app_indicator.set_title(self->tray_indicator, self->tray_tooltip);
  }
}

static void DisposeTray(MyApplication* self) {
  if (self->tray_indicator != nullptr) {
    if (g_app_indicator.set_status != nullptr) {
      g_app_indicator.set_status(self->tray_indicator,
                                 kAppIndicatorStatusPassive);
    }
    g_clear_object(&self->tray_indicator);
  }
  g_clear_object(&self->tray_menu);
  self->tray_show_item = nullptr;
  self->tray_downloads_item = nullptr;
  self->tray_quit_item = nullptr;
}

static void RespondSuccess(FlMethodCall* method_call, FlValue* result) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(method_call, result, &error)) {
    g_warning("Failed to respond to method call: %s",
              error != nullptr ? error->message : "unknown");
  }
}

static void desktop_window_method_cb(FlMethodChannel* channel,
                                     FlMethodCall* method_call,
                                     gpointer user_data) {
  (void)channel;
  auto* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "getMetrics") == 0) {
    g_autoptr(FlValue) metrics = BuildWindowMetricsMap(self);
    RespondSuccess(method_call, metrics);
    return;
  }
  if (g_strcmp0(method, "setTitleBarMetrics") == 0 ||
      g_strcmp0(method, "startDragging") == 0 ||
      g_strcmp0(method, "titleBarDoubleClick") == 0) {
    RespondSuccess(method_call, nullptr);
    return;
  }
  if (self->main_window != nullptr) {
    if (g_strcmp0(method, "minimize") == 0) {
      gtk_window_iconify(self->main_window);
      RespondSuccess(method_call, nullptr);
      return;
    }
    if (g_strcmp0(method, "toggleMaximize") == 0) {
      if (self->is_maximized) {
        gtk_window_unmaximize(self->main_window);
      } else {
        gtk_window_maximize(self->main_window);
      }
      RespondSuccess(method_call, nullptr);
      return;
    }
    if (g_strcmp0(method, "close") == 0) {
      gtk_window_close(self->main_window);
      RespondSuccess(method_call, nullptr);
      return;
    }
    if (g_strcmp0(method, "toggleFullScreen") == 0) {
      if (self->is_fullscreen) {
        gtk_window_unfullscreen(self->main_window);
      } else {
        gtk_window_fullscreen(self->main_window);
      }
      RespondSuccess(method_call, nullptr);
      return;
    }
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond not implemented: %s",
              error != nullptr ? error->message : "unknown");
  }
}

static void tray_method_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  (void)channel;
  auto* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "isSupported") == 0) {
    const bool supported = EnsureAppIndicatorLoaded();
    g_autoptr(FlValue) result = fl_value_new_bool(supported);
    RespondSuccess(method_call, result);
    return;
  }
  if (g_strcmp0(method, "initialize") == 0) {
    UpdateTrayLabelsFromArgs(self, fl_method_call_get_args(method_call));
    EnsureTrayInitialized(self);
    RespondSuccess(method_call, nullptr);
    return;
  }
  if (g_strcmp0(method, "updateLabels") == 0) {
    UpdateTrayLabelsFromArgs(self, fl_method_call_get_args(method_call));
    RespondSuccess(method_call, nullptr);
    return;
  }
  if (g_strcmp0(method, "dispose") == 0) {
    DisposeTray(self);
    RespondSuccess(method_call, nullptr);
    return;
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond not implemented: %s",
              error != nullptr ? error->message : "unknown");
  }
}

static void intent_method_cb(FlMethodChannel* channel,
                             FlMethodCall* method_call,
                             gpointer user_data) {
  (void)channel;
  auto* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (g_strcmp0(method, "getInitialIntent") == 0) {
    self->initial_intent_consumed = TRUE;
    if (self->initial_intent_uri != nullptr) {
      g_autoptr(FlValue) payload =
          BuildViewIntentPayload(self->initial_intent_uri);
      g_clear_pointer(&self->initial_intent_uri, g_free);
      RespondSuccess(method_call, payload);
    } else {
      g_autoptr(FlValue) payload = fl_value_new_map();
      fl_value_set_string_take(
          payload, "action",
          fl_value_new_string("android.intent.action.MAIN"));
      RespondSuccess(method_call, payload);
    }
    return;
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond not implemented: %s",
              error != nullptr ? error->message : "unknown");
  }
}

static FlMethodErrorResponse* intent_listen_cb(FlEventChannel* channel,
                                               FlValue* args,
                                               gpointer user_data) {
  (void)channel;
  (void)args;
  auto* self = MY_APPLICATION(user_data);
  self->intent_listening = TRUE;
  if (self->pending_live_uris != nullptr) {
    for (guint i = 0; i < self->pending_live_uris->len; ++i) {
      const auto* uri =
          static_cast<const gchar*>(g_ptr_array_index(self->pending_live_uris, i));
      g_autoptr(FlValue) payload = BuildViewIntentPayload(uri);
      g_autoptr(GError) error = nullptr;
      fl_event_channel_send(self->intent_event_channel, payload, nullptr,
                            &error);
    }
    g_ptr_array_set_size(self->pending_live_uris, 0);
  }
  return nullptr;
}

static FlMethodErrorResponse* intent_cancel_cb(FlEventChannel* channel,
                                               FlValue* args,
                                               gpointer user_data) {
  (void)channel;
  (void)args;
  auto* self = MY_APPLICATION(user_data);
  self->intent_listening = FALSE;
  return nullptr;
}

static gboolean on_window_state_event(GtkWidget* widget,
                                      GdkEventWindowState* event,
                                      gpointer user_data) {
  (void)widget;
  auto* self = MY_APPLICATION(user_data);
  const gboolean next_fullscreen =
      (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
  const gboolean next_maximized =
      (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
  if (self->is_fullscreen != next_fullscreen ||
      self->is_maximized != next_maximized) {
    self->is_fullscreen = next_fullscreen;
    self->is_maximized = next_maximized;
    EmitWindowMetrics(self);
  }
  return FALSE;
}

static void on_window_is_active_changed(GObject* object,
                                        GParamSpec* pspec,
                                        gpointer user_data) {
  (void)object;
  (void)pspec;
  auto* self = MY_APPLICATION(user_data);
  if (self->main_window == nullptr) {
    return;
  }
  const gboolean next_active = gtk_window_is_active(self->main_window);
  if (self->is_active != next_active) {
    self->is_active = next_active;
    EmitWindowMetrics(self);
  }
}

static void on_main_window_destroy(GtkWidget* widget, gpointer user_data) {
  (void)widget;
  auto* self = MY_APPLICATION(user_data);
  self->main_window = nullptr;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  (void)self;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->main_window != nullptr) {
    RestoreAndPresentWindow(self);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->main_window = window;
  self->is_wayland = DetectWaylandSession(window);
  self->is_active = TRUE;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Parfait");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Parfait");
  }

  // The same desktop default as the Windows runner and
  // lib/app/window/window_geometry.dart; the saved place replaces it before
  // the window is shown.
  gtk_window_set_default_size(window, 1280, 800);
  GdkGeometry geometry = {};
  geometry.min_width = 480;
  geometry.min_height = 640;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(on_window_state_event), self);
  g_signal_connect(window, "notify::is-active",
                   G_CALLBACK(on_window_is_active_changed), self);
  g_signal_connect(window, "destroy", G_CALLBACK(on_main_window_destroy), self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
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

  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  self->desktop_window_channel = fl_method_channel_new(
      messenger, "parfait/desktop_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->desktop_window_channel, desktop_window_method_cb, self, nullptr);

  self->tray_channel =
      fl_method_channel_new(messenger, "parfait/tray", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->tray_channel, tray_method_cb,
                                            self, nullptr);

  self->intent_channel = fl_method_channel_new(
      messenger, "parfait/android_intents", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->intent_channel, intent_method_cb, self, nullptr);

  self->intent_event_channel = fl_event_channel_new(
      messenger, "parfait/android_intents/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      self->intent_event_channel, intent_listen_cb, intent_cancel_cb, self,
      nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::command_line for single-instance URI forwarding.
static gint my_application_command_line(GApplication* application,
                                        GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  gint argc = 0;
  gchar** argv = g_application_command_line_get_arguments(command_line, &argc);
  const gchar* uri =
      (argv != nullptr && argc > 1) ? ExtractSupportedUriFromStrv(argv + 1)
                                    : nullptr;

  if (self->main_window == nullptr) {
    if (self->dart_entrypoint_arguments == nullptr) {
      self->dart_entrypoint_arguments =
          (argv != nullptr && argv[0] != nullptr) ? g_strdupv(argv + 1)
                                                  : nullptr;
    }
    if (uri != nullptr) {
      DeliverExternalUri(self, uri);
    }
    g_application_activate(application);
  } else {
    RestoreAndPresentWindow(self);
    if (uri != nullptr) {
      DeliverExternalUri(self, uri);
    }
  }

  g_strfreev(argv);
  g_application_command_line_set_exit_status(command_line, 0);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  DisposeTray(self);
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  DisposeTray(self);
  if (self->desktop_window_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->desktop_window_channel,
                                              nullptr, nullptr, nullptr);
    g_clear_object(&self->desktop_window_channel);
  }
  if (self->tray_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->tray_channel, nullptr,
                                              nullptr, nullptr);
    g_clear_object(&self->tray_channel);
  }
  if (self->intent_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->intent_channel, nullptr,
                                              nullptr, nullptr);
    g_clear_object(&self->intent_channel);
  }
  if (self->intent_event_channel != nullptr) {
    fl_event_channel_set_stream_handlers(self->intent_event_channel, nullptr,
                                         nullptr, nullptr, nullptr);
    g_clear_object(&self->intent_event_channel);
  }
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->initial_intent_uri, g_free);
  g_clear_pointer(&self->pending_live_uris, g_ptr_array_unref);
  g_clear_pointer(&self->tray_tooltip, g_free);
  g_clear_pointer(&self->tray_show_label, g_free);
  g_clear_pointer(&self->tray_downloads_label, g_free);
  g_clear_pointer(&self->tray_quit_label, g_free);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(
      g_object_new(my_application_get_type(), "application-id", APPLICATION_ID,
                   "flags", G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
