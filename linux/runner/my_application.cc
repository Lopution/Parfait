#include "my_application.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>

#include <cstdint>
#include <cstring>
#include <limits>

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

#if !(defined(PARFAIT_DEV_TARGET) && PARFAIT_DEV_TARGET)
bool IsTruthyEnv(const char* name) {
  const gchar* val = g_getenv(name);
  return val != nullptr && (val[0] == '1' || val[0] == 't' || val[0] == 'T');
}

bool HasNonEmptyEnv(const char* name) {
  const gchar* val = g_getenv(name);
  return val != nullptr && val[0] != '\0';
}

bool HasDevEnvConfiguration() {
  return IsTruthyEnv("PARFAIT_DEV_PROFILE") ||
         IsTruthyEnv("PARFAIT_DEV_INSTANCE") ||
         HasNonEmptyEnv("PARFAIT_DEV_ROOT") ||
         HasNonEmptyEnv("PARFAIT_DEV_PROFILE_NAME") ||
         HasNonEmptyEnv("PARFAIT_WORKBENCH_URL") ||
         HasNonEmptyEnv("PARFAIT_DEV_WORKBENCH_URL") ||
         HasNonEmptyEnv("PARFAIT_DEV_SOURCE") ||
         HasNonEmptyEnv("PARFAIT_DEV_LOOPBACK_URL");
}
#endif

const gchar* ResolveApplicationId() {
  const gchar* env_id = g_getenv("PARFAIT_APP_ID");
  if (env_id != nullptr && env_id[0] != '\0') {
    return env_id;
  }
#if defined(PARFAIT_DEV_TARGET) && PARFAIT_DEV_TARGET
  return "io.github.lopution.parfait.dev";
#else
  if (HasDevEnvConfiguration()) {
    return "io.github.lopution.parfait.dev";
  }
  return APPLICATION_ID;
#endif
}

const gchar* ResolveTrayIconName() {
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  if (theme != nullptr) {
    const gchar* app_id = ResolveApplicationId();
    if (gtk_icon_theme_has_icon(theme, app_id)) {
      return app_id;
    }
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
  gboolean file_drop_listening;
  gboolean file_drop_active;

  FlMethodChannel* desktop_window_channel;
  FlMethodChannel* tray_channel;
  FlMethodChannel* image_clipboard_channel;
  FlMethodChannel* desktop_file_actions_channel;
  FlEventChannel* file_drop_event_channel;
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
      ResolveApplicationId(), ResolveTrayIconName(),
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

static constexpr gsize kMaxClipboardImageBytes = 32 * 1024 * 1024;
static uint64_t g_linux_clipboard_copy_seq = 0;

static bool HasPngSignature(const uint8_t* data, gsize len) {
  static constexpr uint8_t kSig[8] = {0x89, 0x50, 0x4E, 0x47,
                                      0x0D, 0x0A, 0x1A, 0x0A};
  return data != nullptr && len >= sizeof(kSig) &&
         std::memcmp(data, kSig, sizeof(kSig)) == 0;
}

struct LinuxClipboardImageOwner {
  GBytes* png_bytes = nullptr;
  GdkPixbuf* pixbuf = nullptr;
};

static void linux_clipboard_image_get_cb(GtkClipboard* clipboard,
                                         GtkSelectionData* selection_data,
                                         guint info,
                                         gpointer user_data) {
  (void)clipboard;
  (void)info;
  auto* owner = static_cast<LinuxClipboardImageOwner*>(user_data);
  if (owner == nullptr) {
    return;
  }
  GdkAtom target = gtk_selection_data_get_target(selection_data);
  GdkAtom png_atom = gdk_atom_intern_static_string("image/png");
  if (target == png_atom && owner->png_bytes != nullptr) {
    gsize size = 0;
    const guchar* data = static_cast<const guchar*>(
        g_bytes_get_data(owner->png_bytes, &size));
    if (data != nullptr && size > 0) {
      gtk_selection_data_set(selection_data, target, 8, data,
                             static_cast<gint>(size));
      return;
    }
  }
  if (owner->pixbuf != nullptr) {
    gtk_selection_data_set_pixbuf(selection_data, owner->pixbuf);
  }
}

static void linux_clipboard_image_clear_cb(GtkClipboard* clipboard,
                                           gpointer user_data) {
  (void)clipboard;
  auto* owner = static_cast<LinuxClipboardImageOwner*>(user_data);
  if (owner == nullptr) {
    return;
  }
  if (owner->png_bytes != nullptr) {
    g_bytes_unref(owner->png_bytes);
  }
  if (owner->pixbuf != nullptr) {
    g_object_unref(owner->pixbuf);
  }
  delete owner;
}

struct LinuxCopyImageTaskData {
  gchar* path = nullptr;
  uint64_t seq = 0;
  FlMethodCall* call = nullptr;
  GBytes* png_bytes = nullptr;
  GdkPixbuf* pixbuf = nullptr;
  bool ok = false;

  ~LinuxCopyImageTaskData() {
    g_free(path);
    if (call != nullptr) {
      g_object_unref(call);
    }
    if (png_bytes != nullptr) {
      g_bytes_unref(png_bytes);
    }
    if (pixbuf != nullptr) {
      g_object_unref(pixbuf);
    }
  }
};

static void destroy_copy_image_task_data(gpointer data) {
  delete static_cast<LinuxCopyImageTaskData*>(data);
}

static void copy_image_worker_thread(GTask* task,
                                     gpointer source_object,
                                     gpointer task_data,
                                     GCancellable* cancellable) {
  (void)source_object;
  (void)cancellable;
  auto* data = static_cast<LinuxCopyImageTaskData*>(task_data);
  gchar* contents = nullptr;
  gsize length = 0;
  g_autoptr(GError) error = nullptr;
  if (data->path == nullptr ||
      !g_file_get_contents(data->path, &contents, &length, &error) ||
      contents == nullptr || length == 0 || length > kMaxClipboardImageBytes) {
    g_free(contents);
    g_task_return_boolean(task, FALSE);
    return;
  }

  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  if (!gdk_pixbuf_loader_write(loader,
                               reinterpret_cast<const guchar*>(contents),
                               length, &error) ||
      !gdk_pixbuf_loader_close(loader, &error)) {
    g_free(contents);
    g_task_return_boolean(task, FALSE);
    return;
  }
  GdkPixbuf* loaded = gdk_pixbuf_loader_get_pixbuf(loader);
  if (loaded == nullptr) {
    g_free(contents);
    g_task_return_boolean(task, FALSE);
    return;
  }

  data->pixbuf = GDK_PIXBUF(g_object_ref(loaded));
  if (HasPngSignature(reinterpret_cast<const uint8_t*>(contents), length)) {
    data->png_bytes = g_bytes_new_take(contents, length);
    data->ok = true;
  } else {
    g_free(contents);
    gchar* encoded = nullptr;
    gsize encoded_size = 0;
    if (gdk_pixbuf_save_to_buffer(data->pixbuf, &encoded, &encoded_size, "png",
                                  &error, nullptr) &&
        encoded != nullptr && encoded_size > 0 &&
        encoded_size <= kMaxClipboardImageBytes) {
      data->png_bytes = g_bytes_new_take(encoded, encoded_size);
      data->ok = true;
    } else {
      g_free(encoded);
    }
  }
  g_task_return_boolean(task, data->ok ? TRUE : FALSE);
}

static void copy_image_task_done_cb(GObject* source_object,
                                    GAsyncResult* res,
                                    gpointer user_data) {
  (void)source_object;
  (void)user_data;
  GTask* task = G_TASK(res);
  auto* data = static_cast<LinuxCopyImageTaskData*>(g_task_get_task_data(task));
  bool copied = false;
  if (data != nullptr && data->ok && data->seq == g_linux_clipboard_copy_seq &&
      data->png_bytes != nullptr && data->pixbuf != nullptr) {
    GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    if (clipboard != nullptr) {
      GtkTargetList* target_list = gtk_target_list_new(nullptr, 0);
      gtk_target_list_add_image_targets(target_list, 0, TRUE);
      gint n_targets = 0;
      GtkTargetEntry* targets =
          gtk_target_table_new_from_list(target_list, &n_targets);
      auto* owner = new LinuxClipboardImageOwner();
      owner->png_bytes = g_bytes_ref(data->png_bytes);
      owner->pixbuf = GDK_PIXBUF(g_object_ref(data->pixbuf));
      if (targets != nullptr && n_targets > 0 &&
          gtk_clipboard_set_with_data(clipboard, targets, n_targets,
                                      linux_clipboard_image_get_cb,
                                      linux_clipboard_image_clear_cb, owner)) {
        gtk_clipboard_set_can_store(clipboard, targets, n_targets);
        copied = true;
      } else {
        linux_clipboard_image_clear_cb(clipboard, owner);
      }
      if (targets != nullptr) {
        gtk_target_table_free(targets, n_targets);
      }
      gtk_target_list_unref(target_list);
    }
  }
  if (data != nullptr && data->call != nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(copied ? TRUE : FALSE);
    RespondSuccess(data->call, result);
  }
}

struct LinuxPasteWriteTaskData {
  gchar* target_path = nullptr;
  FlMethodCall* call = nullptr;
  GBytes* raw_png = nullptr;
  GdkPixbuf* pixbuf = nullptr;

  ~LinuxPasteWriteTaskData() {
    g_free(target_path);
    if (call != nullptr) {
      g_object_unref(call);
    }
    if (raw_png != nullptr) {
      g_bytes_unref(raw_png);
    }
    if (pixbuf != nullptr) {
      g_object_unref(pixbuf);
    }
  }
};

static void destroy_paste_write_task_data(gpointer data) {
  delete static_cast<LinuxPasteWriteTaskData*>(data);
}

static void paste_write_worker_thread(GTask* task,
                                      gpointer source_object,
                                      gpointer task_data,
                                      GCancellable* cancellable) {
  (void)source_object;
  (void)cancellable;
  auto* data = static_cast<LinuxPasteWriteTaskData*>(task_data);
  if (data == nullptr || data->target_path == nullptr) {
    g_task_return_boolean(task, FALSE);
    return;
  }
  g_autoptr(GError) error = nullptr;
  if (data->raw_png != nullptr) {
    gsize size = 0;
    const gchar* bytes =
        static_cast<const gchar*>(g_bytes_get_data(data->raw_png, &size));
    const gboolean ok =
        bytes != nullptr && size > 0 && size <= kMaxClipboardImageBytes &&
        g_file_set_contents(data->target_path, bytes,
                            static_cast<gssize>(size), &error);
    g_task_return_boolean(task, ok);
    return;
  }
  if (data->pixbuf != nullptr) {
    gchar* buffer = nullptr;
    gsize size = 0;
    gboolean ok = FALSE;
    if (gdk_pixbuf_save_to_buffer(data->pixbuf, &buffer, &size, "png", &error,
                                  nullptr) &&
        buffer != nullptr && size > 0 && size <= kMaxClipboardImageBytes) {
      ok = g_file_set_contents(data->target_path, buffer,
                               static_cast<gssize>(size), &error);
    }
    g_free(buffer);
    g_task_return_boolean(task, ok);
    return;
  }
  g_task_return_boolean(task, FALSE);
}

static void paste_write_task_done_cb(GObject* source_object,
                                     GAsyncResult* res,
                                     gpointer user_data) {
  (void)source_object;
  (void)user_data;
  GTask* task = G_TASK(res);
  auto* data =
      static_cast<LinuxPasteWriteTaskData*>(g_task_get_task_data(task));
  const gboolean wrote = g_task_propagate_boolean(task, nullptr);
  if (data != nullptr && data->call != nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(wrote);
    RespondSuccess(data->call, result);
  }
}

struct LinuxPasteRequestState {
  gchar* target_path = nullptr;
  FlMethodCall* call = nullptr;
};

static void linux_clipboard_pixbuf_received_cb(GtkClipboard* clipboard,
                                               GdkPixbuf* pixbuf,
                                               gpointer user_data) {
  (void)clipboard;
  auto* state = static_cast<LinuxPasteRequestState*>(user_data);
  if (pixbuf == nullptr) {
    g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
    RespondSuccess(state->call, result);
    g_free(state->target_path);
    g_object_unref(state->call);
    delete state;
    return;
  }
  auto* task_data = new LinuxPasteWriteTaskData();
  task_data->target_path = state->target_path;
  task_data->call = state->call;
  task_data->pixbuf = GDK_PIXBUF(g_object_ref(pixbuf));
  delete state;

  g_autoptr(GTask) task =
      g_task_new(nullptr, nullptr, paste_write_task_done_cb, nullptr);
  g_task_set_task_data(task, task_data, destroy_paste_write_task_data);
  g_task_run_in_thread(task, paste_write_worker_thread);
}

static void linux_clipboard_png_received_cb(GtkClipboard* clipboard,
                                            GtkSelectionData* selection_data,
                                            gpointer user_data) {
  auto* state = static_cast<LinuxPasteRequestState*>(user_data);
  const gint length = selection_data != nullptr
                          ? gtk_selection_data_get_length(selection_data)
                          : -1;
  const guchar* raw =
      length > 0 ? gtk_selection_data_get_data(selection_data) : nullptr;
  if (raw != nullptr && length > 0 &&
      static_cast<gsize>(length) <= kMaxClipboardImageBytes) {
    auto* task_data = new LinuxPasteWriteTaskData();
    task_data->target_path = state->target_path;
    task_data->call = state->call;
    task_data->raw_png = g_bytes_new(raw, static_cast<gsize>(length));
    delete state;

    g_autoptr(GTask) task =
        g_task_new(nullptr, nullptr, paste_write_task_done_cb, nullptr);
    g_task_set_task_data(task, task_data, destroy_paste_write_task_data);
    g_task_run_in_thread(task, paste_write_worker_thread);
    return;
  }
  gtk_clipboard_request_image(clipboard, linux_clipboard_pixbuf_received_cb,
                              state);
}

static const gchar* OpenLocalFileOnLinux(const gchar* path) {
  if (path == nullptr || path[0] == '\0') {
    return "failed";
  }
  if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
    return "notFound";
  }
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* uri = g_filename_to_uri(path, nullptr, &error);
  if (uri == nullptr) {
    return "failed";
  }
  if (g_app_info_launch_default_for_uri(uri, nullptr, &error)) {
    return "opened";
  }
  return "failed";
}

static const gchar* ShowLocalFileInFolderOnLinux(const gchar* path) {
  if (path == nullptr || path[0] == '\0') {
    return "failed";
  }
  if (!g_file_test(path, G_FILE_TEST_EXISTS)) {
    return "notFound";
  }
  g_autoptr(GError) uri_error = nullptr;
  g_autofree gchar* file_uri = g_filename_to_uri(path, nullptr, &uri_error);
  if (file_uri != nullptr) {
    g_autoptr(GError) bus_error = nullptr;
    g_autoptr(GDBusConnection) bus =
        g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
    if (bus != nullptr) {
      const gchar* uris[2] = {file_uri, nullptr};
      g_autoptr(GError) call_error = nullptr;
      g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
          bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
          "org.freedesktop.FileManager1", "ShowItems",
          g_variant_new("(^ass)", uris, ""), nullptr, G_DBUS_CALL_FLAGS_NONE,
          1500, nullptr, &call_error);
      if (reply != nullptr) {
        return "opened";
      }
    }
  }
  g_autofree gchar* dir = g_path_get_dirname(path);
  if (dir == nullptr || dir[0] == '\0') {
    return "failed";
  }
  g_autoptr(GError) dir_error = nullptr;
  g_autofree gchar* dir_uri = g_filename_to_uri(dir, nullptr, &dir_error);
  if (dir_uri == nullptr) {
    return "failed";
  }
  if (g_app_info_launch_default_for_uri(dir_uri, nullptr, &dir_error)) {
    return "opened";
  }
  return "failed";
}

static void desktop_file_actions_method_cb(FlMethodChannel* channel,
                                           FlMethodCall* method_call,
                                           gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(method_call);
  const gchar* path = ReadMapString(fl_method_call_get_args(method_call), "path");
  if (g_strcmp0(method, "openFile") == 0) {
    g_autoptr(FlValue) result = fl_value_new_string(OpenLocalFileOnLinux(path));
    RespondSuccess(method_call, result);
    return;
  }
  if (g_strcmp0(method, "showInFolder") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_string(ShowLocalFileInFolderOnLinux(path));
    RespondSuccess(method_call, result);
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

static void EmitFileDropEvent(MyApplication* self,
                              const gchar* type,
                              GPtrArray* paths) {
  if (self->file_drop_event_channel == nullptr || !self->file_drop_listening ||
      type == nullptr) {
    return;
  }
  g_autoptr(FlValue) payload = fl_value_new_map();
  fl_value_set_string_take(payload, "type", fl_value_new_string(type));
  if (paths != nullptr && paths->len > 0) {
    FlValue* list = fl_value_new_list();
    for (guint i = 0; i < paths->len; ++i) {
      const auto* p = static_cast<const gchar*>(g_ptr_array_index(paths, i));
      if (p != nullptr && p[0] != '\0') {
        fl_value_append_take(list, fl_value_new_string(p));
      }
    }
    fl_value_set_string_take(payload, "paths", list);
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_event_channel_send(self->file_drop_event_channel, payload, nullptr,
                             &error)) {
    g_warning("Failed to emit file drop event: %s",
              error != nullptr ? error->message : "unknown");
  }
}

static FlMethodErrorResponse* file_drop_listen_cb(FlEventChannel* channel,
                                                  FlValue* args,
                                                  gpointer user_data) {
  (void)channel;
  (void)args;
  auto* self = MY_APPLICATION(user_data);
  self->file_drop_listening = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* file_drop_cancel_cb(FlEventChannel* channel,
                                                  FlValue* args,
                                                  gpointer user_data) {
  (void)channel;
  (void)args;
  auto* self = MY_APPLICATION(user_data);
  self->file_drop_listening = FALSE;
  self->file_drop_active = FALSE;
  return nullptr;
}

static gboolean on_drag_motion(GtkWidget* widget,
                               GdkDragContext* context,
                               gint x,
                               gint y,
                               guint time,
                               gpointer user_data) {
  (void)widget;
  (void)x;
  (void)y;
  auto* self = MY_APPLICATION(user_data);
  if (!self->file_drop_active) {
    self->file_drop_active = TRUE;
    EmitFileDropEvent(self, "entered", nullptr);
  }
  gdk_drag_status(context, GDK_ACTION_COPY, time);
  return TRUE;
}

static void on_drag_leave(GtkWidget* widget,
                          GdkDragContext* context,
                          guint time,
                          gpointer user_data) {
  (void)widget;
  (void)context;
  (void)time;
  auto* self = MY_APPLICATION(user_data);
  if (self->file_drop_active) {
    self->file_drop_active = FALSE;
    EmitFileDropEvent(self, "exited", nullptr);
  }
}

static void on_drag_data_received(GtkWidget* widget,
                                  GdkDragContext* context,
                                  gint x,
                                  gint y,
                                  GtkSelectionData* selection_data,
                                  guint info,
                                  guint time,
                                  gpointer user_data) {
  (void)widget;
  (void)x;
  (void)y;
  (void)info;
  auto* self = MY_APPLICATION(user_data);
  self->file_drop_active = FALSE;
  EmitFileDropEvent(self, "exited", nullptr);

  gchar** uris = gtk_selection_data_get_uris(selection_data);
  gboolean accepted = FALSE;
  if (uris != nullptr) {
    g_autoptr(GPtrArray) paths = g_ptr_array_new_with_free_func(g_free);
    for (int i = 0; uris[i] != nullptr; ++i) {
      g_autoptr(GError) error = nullptr;
      gchar* filename = g_filename_from_uri(uris[i], nullptr, &error);
      if (filename != nullptr) {
        g_ptr_array_add(paths, filename);
      }
    }
    g_strfreev(uris);
    if (paths->len > 0) {
      EmitFileDropEvent(self, "dropped", paths);
      accepted = TRUE;
    }
  }
  gtk_drag_finish(context, accepted, FALSE, time);
}

static void image_clipboard_method_cb(FlMethodChannel* channel,
                                      FlMethodCall* method_call,
                                      gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  if (g_strcmp0(method, "readImageToTempFile") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      g_autoptr(GError) error = nullptr;
      fl_method_call_respond_error(method_call, "INVALID_ARGS",
                                   "Expected argument map", nullptr, &error);
      return;
    }
    FlValue* target_val = fl_value_lookup_string(args, "targetPath");
    if (target_val == nullptr ||
        fl_value_get_type(target_val) != FL_VALUE_TYPE_STRING) {
      g_autoptr(GError) error = nullptr;
      fl_method_call_respond_error(method_call, "INVALID_ARGS",
                                   "Expected targetPath string", nullptr,
                                   &error);
      return;
    }
    const gchar* target_path = fl_value_get_string(target_val);
    GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    if (clipboard == nullptr || target_path == nullptr ||
        target_path[0] == '\0') {
      g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
      RespondSuccess(method_call, result);
      return;
    }
    auto* state = new LinuxPasteRequestState();
    state->target_path = g_strdup(target_path);
    state->call = FL_METHOD_CALL(g_object_ref(method_call));
    gtk_clipboard_request_contents(clipboard,
                                   gdk_atom_intern_static_string("image/png"),
                                   linux_clipboard_png_received_cb, state);
    return;
  }
  if (g_strcmp0(method, "copyImageFile") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      g_autoptr(GError) error = nullptr;
      fl_method_call_respond_error(method_call, "INVALID_ARGS",
                                   "Expected argument map", nullptr, &error);
      return;
    }
    FlValue* path_val = fl_value_lookup_string(args, "path");
    if (path_val == nullptr ||
        fl_value_get_type(path_val) != FL_VALUE_TYPE_STRING) {
      g_autoptr(GError) error = nullptr;
      fl_method_call_respond_error(method_call, "INVALID_ARGS",
                                   "Expected path string", nullptr, &error);
      return;
    }
    const gchar* path = fl_value_get_string(path_val);
    if (path == nullptr || path[0] == '\0') {
      g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
      RespondSuccess(method_call, result);
      return;
    }
    auto* task_data = new LinuxCopyImageTaskData();
    task_data->path = g_strdup(path);
    task_data->seq = ++g_linux_clipboard_copy_seq;
    task_data->call = FL_METHOD_CALL(g_object_ref(method_call));

    g_autoptr(GTask) task =
        g_task_new(nullptr, nullptr, copy_image_task_done_cb, nullptr);
    g_task_set_task_data(task, task_data, destroy_copy_image_task_data);
    g_task_run_in_thread(task, copy_image_worker_thread);
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

  self->image_clipboard_channel = fl_method_channel_new(
      messenger, "parfait/image_clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->image_clipboard_channel,
                                            image_clipboard_method_cb, self,
                                            nullptr);

  self->desktop_file_actions_channel = fl_method_channel_new(
      messenger, "parfait/desktop_file_actions", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->desktop_file_actions_channel, desktop_file_actions_method_cb, self,
      nullptr);

  self->file_drop_event_channel = fl_event_channel_new(
      messenger, "parfait/file_drop/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->file_drop_event_channel,
                                       file_drop_listen_cb, file_drop_cancel_cb,
                                       self, nullptr);

  GtkTargetEntry drop_targets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, 0},
  };
  gtk_drag_dest_set(GTK_WIDGET(view), GTK_DEST_DEFAULT_ALL, drop_targets, 1,
                    GDK_ACTION_COPY);
  g_signal_connect(view, "drag-motion", G_CALLBACK(on_drag_motion), self);
  g_signal_connect(view, "drag-leave", G_CALLBACK(on_drag_leave), self);
  g_signal_connect(view, "drag-data-received",
                   G_CALLBACK(on_drag_data_received), self);

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
  if (self->image_clipboard_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->image_clipboard_channel,
                                              nullptr, nullptr, nullptr);
    g_clear_object(&self->image_clipboard_channel);
  }
  if (self->desktop_file_actions_channel != nullptr) {
    fl_method_channel_set_method_call_handler(
        self->desktop_file_actions_channel, nullptr, nullptr, nullptr);
    g_clear_object(&self->desktop_file_actions_channel);
  }
  if (self->file_drop_event_channel != nullptr) {
    fl_event_channel_set_stream_handlers(self->file_drop_event_channel, nullptr,
                                         nullptr, nullptr, nullptr);
    g_clear_object(&self->file_drop_event_channel);
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
  const gchar* app_id = ResolveApplicationId();
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(app_id);

  return MY_APPLICATION(
      g_object_new(my_application_get_type(), "application-id", app_id,
                   "flags", G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
