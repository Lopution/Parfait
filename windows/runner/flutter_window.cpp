#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <cctype>
#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT_PTR kChildViewSubclassId = 1;
constexpr UINT kTrayCallbackMessage = WM_APP + 2;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayCmdShowWindow = 1001;
constexpr UINT kTrayCmdDownloads = 1002;
constexpr UINT kTrayCmdQuit = 1003;

bool StartsWithCaseInsensitive(const std::string& text, const char* prefix) {
  const std::string p(prefix);
  if (text.size() < p.size()) {
    return false;
  }
  for (size_t i = 0; i < p.size(); ++i) {
    const auto lhs =
        static_cast<char>(std::tolower(static_cast<unsigned char>(text[i])));
    const auto rhs =
        static_cast<char>(std::tolower(static_cast<unsigned char>(p[i])));
    if (lhs != rhs) {
      return false;
    }
  }
  return true;
}

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int required = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (required <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(required), L'\0');
  const int written =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                            static_cast<int>(utf8.size()), out.data(), required);
  if (written <= 0) {
    return std::wstring();
  }
  return out;
}

bool ReadEncodableDouble(const flutter::EncodableValue& value, double* out) {
  if (const auto* d = std::get_if<double>(&value)) {
    *out = *d;
    return true;
  }
  if (const auto* i32 = std::get_if<int32_t>(&value)) {
    *out = static_cast<double>(*i32);
    return true;
  }
  if (const auto* i64 = std::get_if<int64_t>(&value)) {
    *out = static_cast<double>(*i64);
    return true;
  }
  return false;
}

std::string ReadEncodableString(const flutter::EncodableMap& map,
                                const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::string();
  }
  if (const auto* str = std::get_if<std::string>(&it->second)) {
    return *str;
  }
  return std::string();
}

flutter::EncodableMap BuildViewIntentMap(const std::string& uri) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("action"),
       flutter::EncodableValue("android.intent.action.VIEW")},
      {flutter::EncodableValue("uri"), flutter::EncodableValue(uri)},
  };
}

}  // namespace

bool IsSupportedLaunchUri(const std::string& uri) {
  return StartsWithCaseInsensitive(uri, "pixiv://") ||
         StartsWithCaseInsensitive(uri, "parfait://") ||
         StartsWithCaseInsensitive(uri, "http://") ||
         StartsWithCaseInsensitive(uri, "https://");
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::string initial_intent_uri)
    : project_(project),
      initial_intent_uri_(std::move(initial_intent_uri)) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::SetPropW(hwnd, kParfaitMainWindowProp, reinterpret_cast<HANDLE>(1));
    taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
    is_active_ = (::GetForegroundWindow() == hwnd);
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  child_view_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child_view_hwnd_);
  if (child_view_hwnd_ != nullptr) {
    ::SetWindowSubclass(child_view_hwnd_, ChildViewSubclassProc,
                        kChildViewSubclassId, reinterpret_cast<DWORD_PTR>(this));
  }

  RegisterNativeChannels();

  if (hwnd != nullptr) {
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                       SWP_NOACTIVATE);
  }

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();

  if (desktop_window_channel_) {
    desktop_window_channel_->SetMethodCallHandler(nullptr);
    desktop_window_channel_.reset();
  }
  if (tray_channel_) {
    tray_channel_->SetMethodCallHandler(nullptr);
    tray_channel_.reset();
  }
  if (navigation_channel_) {
    navigation_channel_->SetMethodCallHandler(nullptr);
    navigation_channel_.reset();
  }
  if (intent_channel_) {
    intent_channel_->SetMethodCallHandler(nullptr);
    intent_channel_.reset();
  }
  if (intent_event_channel_) {
    intent_event_channel_->SetStreamHandler(nullptr);
    intent_event_channel_.reset();
  }
  intent_event_sink_.reset();

  if (child_view_hwnd_ != nullptr) {
    ::RemoveWindowSubclass(child_view_hwnd_, ChildViewSubclassProc,
                           kChildViewSubclassId);
    child_view_hwnd_ = nullptr;
  }
  if (HWND hwnd = GetHandle(); hwnd != nullptr) {
    ::RemovePropW(hwnd, kParfaitMainWindowProp);
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterNativeChannels() {
  flutter::BinaryMessenger* messenger =
      flutter_controller_->engine()->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();

  desktop_window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/desktop_window", codec);
  desktop_window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        const std::string& method = call.method_name();
        if (method == "getMetrics") {
          result->Success(flutter::EncodableValue(BuildWindowMetricsMap()));
          return;
        }
        if (method == "setTitleBarMetrics") {
          std::vector<TitleBarRegion> next_regions;
          if (call.arguments() != nullptr) {
            if (const auto* map =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              const auto it = map->find(flutter::EncodableValue("regions"));
              if (it != map->end()) {
                if (const auto* list =
                        std::get_if<flutter::EncodableList>(&it->second)) {
                  for (const auto& item : *list) {
                    const auto* tuple =
                        std::get_if<flutter::EncodableList>(&item);
                    if (tuple == nullptr || tuple->size() < 5) {
                      continue;
                    }
                    TitleBarRegion region;
                    if (!ReadEncodableDouble((*tuple)[0], &region.left) ||
                        !ReadEncodableDouble((*tuple)[1], &region.top) ||
                        !ReadEncodableDouble((*tuple)[2], &region.right) ||
                        !ReadEncodableDouble((*tuple)[3], &region.bottom)) {
                      continue;
                    }
                    if (const auto* kind =
                            std::get_if<std::string>(&(*tuple)[4])) {
                      region.kind = *kind;
                      next_regions.push_back(std::move(region));
                    }
                  }
                }
              }
            }
          }
          title_bar_regions_ = std::move(next_regions);
          result->Success();
          return;
        }
        if (method == "minimize") {
          if (hwnd != nullptr) {
            ::ShowWindow(hwnd, SW_MINIMIZE);
          }
          result->Success();
          return;
        }
        if (method == "toggleMaximize" || method == "titleBarDoubleClick") {
          if (hwnd != nullptr) {
            ::PostMessageW(hwnd, WM_SYSCOMMAND,
                           ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
          }
          result->Success();
          return;
        }
        if (method == "close") {
          if (hwnd != nullptr) {
            ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
          }
          result->Success();
          return;
        }
        if (method == "startDragging") {
          if (hwnd != nullptr) {
            ::ReleaseCapture();
            ::SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          }
          result->Success();
          return;
        }
        if (method == "toggleFullScreen") {
          ToggleFullscreen();
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/tray", codec);
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "isSupported") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "initialize" || method == "updateLabels") {
          if (call.arguments() != nullptr) {
            if (const auto* map =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              const std::string tip = ReadEncodableString(*map, "tooltip");
              const std::string show = ReadEncodableString(*map, "showWindow");
              const std::string dl = ReadEncodableString(*map, "downloads");
              const std::string quit = ReadEncodableString(*map, "quit");
              if (!tip.empty()) {
                tray_labels_.tooltip = Utf16FromUtf8(tip);
              }
              if (!show.empty()) {
                tray_labels_.show_window = Utf16FromUtf8(show);
              }
              if (!dl.empty()) {
                tray_labels_.downloads = Utf16FromUtf8(dl);
              }
              if (!quit.empty()) {
                tray_labels_.quit = Utf16FromUtf8(quit);
              }
            }
          }
          if (method == "initialize") {
            EnsureTrayIcon();
          } else {
            UpdateTrayIconTip();
          }
          result->Success();
          return;
        }
        if (method == "dispose") {
          RemoveTrayIcon();
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  navigation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/navigation_commands", codec);

  intent_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "parfait/android_intents", codec);
  intent_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "getInitialIntent") {
          initial_intent_consumed_ = true;
          if (!initial_intent_uri_.empty()) {
            const std::string uri = std::move(initial_intent_uri_);
            initial_intent_uri_.clear();
            result->Success(flutter::EncodableValue(BuildViewIntentMap(uri)));
          } else {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("action"),
                 flutter::EncodableValue("android.intent.action.MAIN")},
            }));
          }
          return;
        }
        result->NotImplemented();
      });

  intent_event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "parfait/android_intents/events", codec);
  intent_event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            intent_event_sink_ = std::move(events);
            if (!pending_live_uris_.empty() && intent_event_sink_) {
              for (const auto& uri : pending_live_uris_) {
                intent_event_sink_->Success(
                    flutter::EncodableValue(BuildViewIntentMap(uri)));
              }
              pending_live_uris_.clear();
            }
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            intent_event_sink_.reset();
            return nullptr;
          }));
}

flutter::EncodableMap FlutterWindow::BuildWindowMetricsMap() const {
  HWND hwnd = GetHandle();
  const bool zoomed = hwnd != nullptr && ::IsZoomed(hwnd) != FALSE;
  return flutter::EncodableMap{
      {flutter::EncodableValue("isWayland"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("usesSystemTitleBar"),
       flutter::EncodableValue(false)},
      {flutter::EncodableValue("isFullScreen"),
       flutter::EncodableValue(IsFullscreenState())},
      {flutter::EncodableValue("isMaximized"), flutter::EncodableValue(zoomed)},
      {flutter::EncodableValue("isActive"),
       flutter::EncodableValue(is_active_)},
      {flutter::EncodableValue("trafficLightWidth"),
       flutter::EncodableValue(0.0)},
      {flutter::EncodableValue("trafficLightHeight"),
       flutter::EncodableValue(0.0)},
      {flutter::EncodableValue("hoveredButton"),
       flutter::EncodableValue(hovered_button_)},
      {flutter::EncodableValue("pressedButton"),
       flutter::EncodableValue(pressed_button_)},
  };
}

void FlutterWindow::EmitWindowMetrics() {
  if (!desktop_window_channel_) {
    return;
  }
  desktop_window_channel_->InvokeMethod(
      "metricsChanged",
      std::make_unique<flutter::EncodableValue>(BuildWindowMetricsMap()));
}

LRESULT CALLBACK FlutterWindow::ChildViewSubclassProc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    UINT_PTR subclass_id,
    DWORD_PTR ref_data) noexcept {
  auto* self = reinterpret_cast<FlutterWindow*>(ref_data);
  if (message == WM_NCHITTEST && self != nullptr) {
    const LRESULT hit =
        self->HitTestNonClient(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
    if (hit != HTCLIENT) {
      return HTTRANSPARENT;
    }
  } else if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(hwnd, ChildViewSubclassProc, subclass_id);
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT FlutterWindow::HitTestNonClient(int screen_x, int screen_y) const {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return HTCLIENT;
  }

  RECT window_rect{};
  if (!::GetWindowRect(hwnd, &window_rect)) {
    return HTCLIENT;
  }

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);

  const bool resizable =
      !IsFullscreenState() && ::IsZoomed(hwnd) == FALSE &&
      (::GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_THICKFRAME) != 0;
  if (resizable) {
    const int border_x = ::GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                         ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int border_y = ::GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                         ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const bool on_left =
        screen_x >= window_rect.left && screen_x < window_rect.left + border_x;
    const bool on_right = screen_x < window_rect.right &&
                          screen_x >= window_rect.right - border_x;
    const bool on_top =
        screen_y >= window_rect.top && screen_y < window_rect.top + border_y;
    const bool on_bottom = screen_y < window_rect.bottom &&
                           screen_y >= window_rect.bottom - border_y;

    if (on_top && on_left) return HTTOPLEFT;
    if (on_top && on_right) return HTTOPRIGHT;
    if (on_bottom && on_left) return HTBOTTOMLEFT;
    if (on_bottom && on_right) return HTBOTTOMRIGHT;
    if (on_left) return HTLEFT;
    if (on_right) return HTRIGHT;
    if (on_top) return HTTOP;
    if (on_bottom) return HTBOTTOM;
  }

  POINT client_pt{screen_x, screen_y};
  if (!::ScreenToClient(hwnd, &client_pt)) {
    return HTCLIENT;
  }
  const double scale = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
  const double lx = static_cast<double>(client_pt.x) / scale;
  const double ly = static_cast<double>(client_pt.y) / scale;

  for (const auto& region : title_bar_regions_) {
    if (region.kind == "maximize" && lx >= region.left && lx < region.right &&
        ly >= region.top && ly < region.bottom) {
      return HTMAXBUTTON;
    }
  }
  for (const auto& region : title_bar_regions_) {
    if (region.kind == "caption" && lx >= region.left && lx < region.right &&
        ly >= region.top && ly < region.bottom) {
      return HTCAPTION;
    }
  }

  return HTCLIENT;
}

void FlutterWindow::ToggleFullscreen() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  if (!IsFullscreenState()) {
    saved_style_ = ::GetWindowLongPtrW(hwnd, GWL_STYLE);
    saved_placement_.length = sizeof(saved_placement_);
    if (!::GetWindowPlacement(hwnd, &saved_placement_)) {
      return;
    }
    HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!::GetMonitorInfoW(monitor, &mi)) {
      return;
    }
    SetFullscreenState(true);
    EmitWindowMetrics();
    ::SetWindowLongPtrW(
        hwnd, GWL_STYLE,
        saved_style_ & ~static_cast<LONG_PTR>(WS_CAPTION | WS_THICKFRAME));
    ::SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                   mi.rcMonitor.right - mi.rcMonitor.left,
                   mi.rcMonitor.bottom - mi.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetFullscreenState(false);
    EmitWindowMetrics();
    if (saved_style_ != 0) {
      ::SetWindowLongPtrW(hwnd, GWL_STYLE, saved_style_);
    }
    if (saved_placement_.length == sizeof(saved_placement_)) {
      ::SetWindowPlacement(hwnd, &saved_placement_);
    }
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
  }
  EmitWindowMetrics();
}

void FlutterWindow::RestoreAndFocusWindow() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_SHOWMAXIMIZED : SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
  ::BringWindowToTop(hwnd);
  if (child_view_hwnd_ != nullptr) {
    ::SetFocus(child_view_hwnd_);
  }
}

void FlutterWindow::SendNavigationCommand(const char* command) {
  if (!navigation_channel_) {
    return;
  }
  navigation_channel_->InvokeMethod(command, nullptr);
}

void FlutterWindow::DeliverExternalUri(const std::string& uri) {
  if (!IsSupportedLaunchUri(uri)) {
    return;
  }
  if (intent_event_sink_) {
    intent_event_sink_->Success(flutter::EncodableValue(BuildViewIntentMap(uri)));
  } else if (initial_intent_consumed_) {
    pending_live_uris_.push_back(uri);
  } else {
    initial_intent_uri_ = uri;
  }
}

void FlutterWindow::EnsureTrayIcon() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (!tray_initialized_) {
    tray_icon_data_ = {};
    tray_icon_data_.cbSize = sizeof(tray_icon_data_);
    tray_icon_data_.hWnd = hwnd;
    tray_icon_data_.uID = kTrayIconId;
    tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray_icon_data_.uCallbackMessage = kTrayCallbackMessage;
    tray_icon_data_.hIcon = ::LoadIconW(
        ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
    UpdateTrayIconTip();
    if (::Shell_NotifyIconW(NIM_ADD, &tray_icon_data_)) {
      tray_initialized_ = true;
    }
    return;
  }
  UpdateTrayIconTip();
}

void FlutterWindow::UpdateTrayIconTip() {
  const size_t max_chars =
      (sizeof(tray_icon_data_.szTip) / sizeof(wchar_t)) - 1;
  const std::wstring& tip = tray_labels_.tooltip;
  const size_t count = std::min(tip.size(), max_chars);
  for (size_t i = 0; i < count; ++i) {
    tray_icon_data_.szTip[i] = tip[i];
  }
  tray_icon_data_.szTip[count] = L'\0';
  if (tray_initialized_) {
    tray_icon_data_.uFlags = NIF_TIP;
    ::Shell_NotifyIconW(NIM_MODIFY, &tray_icon_data_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_initialized_) {
    ::Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
    tray_initialized_ = false;
  }
}

void FlutterWindow::ShowTrayContextMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  POINT pt{};
  if (!::GetCursorPos(&pt)) {
    return;
  }
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kTrayCmdShowWindow,
                tray_labels_.show_window.c_str());
  ::AppendMenuW(menu, MF_STRING, kTrayCmdDownloads,
                tray_labels_.downloads.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayCmdQuit, tray_labels_.quit.c_str());

  ::SetForegroundWindow(hwnd);
  const BOOL cmd = ::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, hwnd, nullptr);
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  switch (cmd) {
    case kTrayCmdShowWindow:
      RestoreAndFocusWindow();
      SendTrayAction("showWindow");
      break;
    case kTrayCmdDownloads:
      RestoreAndFocusWindow();
      SendTrayAction("openDownloads");
      break;
    case kTrayCmdQuit:
      SendTrayAction("quit");
      break;
    default:
      break;
  }
}

void FlutterWindow::SendTrayAction(const char* action) {
  if (!tray_channel_) {
    return;
  }
  tray_channel_->InvokeMethod(
      "onTrayAction",
      std::make_unique<flutter::EncodableValue>(std::string(action)));
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (tray_initialized_) {
      tray_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
      ::Shell_NotifyIconW(NIM_ADD, &tray_icon_data_);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;

    case WM_NCHITTEST:
      return HitTestNonClient(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));

    case WM_NCMOUSEMOVE: {
      const std::string next_hover =
          (wparam == HTMAXBUTTON) ? "maximize" : std::string();
      if (!next_hover.empty() && !tracking_nc_leave_) {
        TRACKMOUSEEVENT tme{};
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE | TME_NONCLIENT;
        tme.hwndTrack = hwnd;
        tracking_nc_leave_ = ::TrackMouseEvent(&tme) != FALSE;
      }
      if (pressed_button_.empty() && hovered_button_ != next_hover) {
        hovered_button_ = next_hover;
        EmitWindowMetrics();
      }
      break;
    }

    case WM_NCMOUSELEAVE:
      tracking_nc_leave_ = false;
      if (pressed_button_.empty() && !hovered_button_.empty()) {
        hovered_button_.clear();
        EmitWindowMetrics();
      }
      return 0;

    case WM_NCLBUTTONDOWN:
      if (wparam == HTMAXBUTTON) {
        pressed_button_ = "maximize";
        hovered_button_ = "maximize";
        ::SetCapture(hwnd);
        EmitWindowMetrics();
        return 0;
      }
      break;

    case WM_NCLBUTTONDBLCLK:
      if (wparam == HTMAXBUTTON) {
        return 0;
      }
      break;

    case WM_MOUSEMOVE:
      if (pressed_button_ == "maximize") {
        POINT pt{};
        if (::GetCursorPos(&pt)) {
          const bool over = HitTestNonClient(pt.x, pt.y) == HTMAXBUTTON;
          const std::string next_hover = over ? "maximize" : std::string();
          if (hovered_button_ != next_hover) {
            hovered_button_ = next_hover;
            EmitWindowMetrics();
          }
        }
        return 0;
      }
      break;

    case WM_LBUTTONUP:
      if (pressed_button_ == "maximize") {
        ::ReleaseCapture();
        pressed_button_.clear();
        POINT pt{};
        const bool over =
            ::GetCursorPos(&pt) && HitTestNonClient(pt.x, pt.y) == HTMAXBUTTON;
        hovered_button_.clear();
        EmitWindowMetrics();
        if (over) {
          ::PostMessageW(hwnd, WM_SYSCOMMAND,
                         ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        }
        return 0;
      }
      break;

    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        const bool trigger = (pressed_button_ == "maximize");
        pressed_button_.clear();
        hovered_button_.clear();
        EmitWindowMetrics();
        if (trigger) {
          ::PostMessageW(hwnd, WM_SYSCOMMAND,
                         ::IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        }
        return 0;
      }
      break;

    case WM_CAPTURECHANGED:
      if (!pressed_button_.empty()) {
        pressed_button_.clear();
        EmitWindowMetrics();
      }
      break;

    case WM_NCRBUTTONUP:
      if (wparam == HTCAPTION) {
        HMENU sys_menu = ::GetSystemMenu(hwnd, FALSE);
        if (sys_menu != nullptr) {
          const bool zoomed = ::IsZoomed(hwnd) != FALSE;
          ::EnableMenuItem(sys_menu, SC_RESTORE,
                           MF_BYCOMMAND | (zoomed ? MF_ENABLED : MF_GRAYED));
          ::EnableMenuItem(sys_menu, SC_MAXIMIZE,
                           MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          ::EnableMenuItem(sys_menu, SC_SIZE,
                           MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          ::EnableMenuItem(sys_menu, SC_MOVE,
                           MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
          const BOOL cmd = ::TrackPopupMenuEx(
              sys_menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, GET_X_LPARAM(lparam),
              GET_Y_LPARAM(lparam), hwnd, nullptr);
          if (cmd > 0) {
            ::PostMessageW(hwnd, WM_SYSCOMMAND, static_cast<WPARAM>(cmd), 0);
          }
          return 0;
        }
      }
      break;

    case WM_COPYDATA: {
      const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (cds != nullptr && cds->dwData == kCopyDataOpenUriTag) {
        RestoreAndFocusWindow();
        if (cds->cbData > 0 && cds->lpData != nullptr) {
          const std::string uri(static_cast<const char*>(cds->lpData),
                                cds->cbData);
          DeliverExternalUri(uri);
        }
        return TRUE;
      }
      break;
    }

    case WM_APPCOMMAND: {
      const UINT cmd = GET_APPCOMMAND_LPARAM(lparam);
      if (cmd == APPCOMMAND_BROWSER_BACKWARD) {
        SendNavigationCommand("back");
        return TRUE;
      }
      if (cmd == APPCOMMAND_BROWSER_FORWARD) {
        SendNavigationCommand("forward");
        return TRUE;
      }
      break;
    }

    case kTrayCallbackMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          RestoreAndFocusWindow();
          SendTrayAction("showWindow");
          break;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayContextMenu();
          break;
        default:
          break;
      }
      return 0;

    case WM_SIZE:
      EmitWindowMetrics();
      break;

    case WM_ACTIVATE: {
      const bool next_active = (LOWORD(wparam) != WA_INACTIVE);
      if (is_active_ != next_active) {
        is_active_ = next_active;
        EmitWindowMetrics();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
