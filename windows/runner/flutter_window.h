#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

inline constexpr wchar_t kParfaitMainWindowProp[] = L"ParfaitMainWindow";
inline constexpr ULONG_PTR kCopyDataOpenUriTag = 0x50465431u;

bool IsSupportedLaunchUri(const std::string& uri);

// A window that hosts a Flutter view alongside custom desktop window chrome,
// single-instance URI routing, mouse side-button navigation, and native tray.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         std::string initial_intent_uri = std::string());
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct TitleBarRegion {
    double left = 0.0;
    double top = 0.0;
    double right = 0.0;
    double bottom = 0.0;
    std::string kind;
  };

  struct TrayLabels {
    std::wstring tooltip = L"Parfait";
    std::wstring show_window = L"Show Window";
    std::wstring downloads = L"Downloads";
    std::wstring quit = L"Quit";
  };

  static LRESULT CALLBACK ChildViewSubclassProc(HWND hwnd,
                                                UINT message,
                                                WPARAM wparam,
                                                LPARAM lparam,
                                                UINT_PTR subclass_id,
                                                DWORD_PTR ref_data) noexcept;

  void RegisterNativeChannels();
  void EmitWindowMetrics();
  flutter::EncodableMap BuildWindowMetricsMap() const;
  LRESULT HitTestNonClient(int screen_x, int screen_y) const;
  void ToggleFullscreen();
  void RestoreAndFocusWindow();
  void SendNavigationCommand(const char* command);
  void DeliverExternalUri(const std::string& uri);

  void EnsureTrayIcon();
  void RemoveTrayIcon();
  void UpdateTrayIconTip();
  void ShowTrayContextMenu();
  void SendTrayAction(const char* action);

  // The project to run.
  flutter::DartProject project_;
  std::string initial_intent_uri_;
  bool initial_intent_consumed_ = false;
  std::vector<std::string> pending_live_uris_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      navigation_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      sensitive_clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      intent_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      intent_event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      intent_event_sink_;

  HWND child_view_hwnd_ = nullptr;
  std::vector<TitleBarRegion> title_bar_regions_;
  std::string hovered_button_;
  std::string pressed_button_;
  bool is_active_ = true;
  bool tracking_nc_leave_ = false;
  WINDOWPLACEMENT saved_placement_{};
  LONG_PTR saved_style_ = 0;

  UINT taskbar_created_message_ = 0;
  bool tray_initialized_ = false;
  NOTIFYICONDATAW tray_icon_data_{};
  TrayLabels tray_labels_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
