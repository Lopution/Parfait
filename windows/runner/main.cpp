#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\io.github.lopution.parfait.SingleInstance";

BOOL CALLBACK FindParfaitWindowCallback(HWND hwnd, LPARAM lparam) {
  if (::GetPropW(hwnd, kParfaitMainWindowProp) != nullptr) {
    *reinterpret_cast<HWND*>(lparam) = hwnd;
    return FALSE;
  }
  return TRUE;
}

HWND FindExistingParfaitWindow() {
  for (int attempt = 0; attempt < 20; ++attempt) {
    HWND found = nullptr;
    ::EnumWindows(FindParfaitWindowCallback, reinterpret_cast<LPARAM>(&found));
    if (found != nullptr) {
      return found;
    }
    ::Sleep(50);
  }
  return nullptr;
}

std::string ExtractInitialUri(const std::vector<std::string>& args) {
  for (const auto& arg : args) {
    if (IsSupportedLaunchUri(arg)) {
      return arg;
    }
  }
  return std::string();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  std::string initial_uri = ExtractInitialUri(command_line_arguments);

  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing_hwnd = FindExistingParfaitWindow();
    if (existing_hwnd != nullptr) {
      DWORD target_pid = 0;
      ::GetWindowThreadProcessId(existing_hwnd, &target_pid);
      if (target_pid != 0) {
        ::AllowSetForegroundWindow(target_pid);
      }
      COPYDATASTRUCT cds{};
      cds.dwData = kCopyDataOpenUriTag;
      cds.cbData = static_cast<DWORD>(initial_uri.size());
      cds.lpData = initial_uri.empty()
                       ? nullptr
                       : const_cast<char*>(initial_uri.data());
      ::SendMessageTimeoutW(existing_hwnd, WM_COPYDATA, 0,
                            reinterpret_cast<LPARAM>(&cds),
                            SMTO_ABORTIFHUNG, 3000, nullptr);
    }
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, std::move(initial_uri));
  Win32Window::Point origin(10, 10);
  // Desktop default: wide enough for the expanded rail and a content column
  // (see lib/app/window/window_geometry.dart, which fits the saved place to
  // a display's work area before the window is shown).
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Parfait", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
