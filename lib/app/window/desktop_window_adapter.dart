import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/desktop_window_channel.dart';

/// Boundary over OS windowing and screen geometry plugins so tests can
/// simulate Wayland errors, close races, and multi-monitor disconnects.
abstract class DesktopWindowAdapter {
  Future<void> ensureInitialized();
  Future<void> setMinimumSize(Size size);
  Future<void> setSize(Size size);
  Future<void> setPosition(Offset position);
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> minimize();
  Future<void> restore();
  Future<void> show();
  Future<void> focus();
  Future<void> hide();
  Future<void> close();
  Future<void> destroy();
  Future<void> setPreventClose(bool prevent);
  Future<void> setFullScreen(bool fullScreen);
  Future<bool> isFullScreen();
  Future<bool> isMaximized();
  Future<bool> isMinimized();
  Future<Size> getSize();
  Future<Offset> getPosition();
  Future<Display> getPrimaryDisplay();
  Future<List<Display>> getAllDisplays();
  void addListener(WindowListener listener);
  void removeListener(WindowListener listener);
}

class WindowManagerAdapter implements DesktopWindowAdapter {
  const WindowManagerAdapter();

  @override
  Future<void> ensureInitialized() => windowManager.ensureInitialized();

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  Future<void> setSize(Size size) => windowManager.setSize(size);

  @override
  Future<void> setPosition(Offset position) =>
      windowManager.setPosition(position);

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> restore() => windowManager.restore();

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> destroy() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      // window_manager 0.5.2's Windows destroy() calls PostQuitMessage(0)
      // without DestroyWindow(hwnd), stranding the window and tearing down
      // COM plugins after CoUninitialize(). Ask the runner to post
      // DestroyWindow onto the live Win32 message queue instead.
      try {
        await const MethodChannel(
          kDesktopWindowChannelName,
        ).invokeMethod<void>('destroy');
        return;
      } on MissingPluginException {
        // Headless tests or runners without the native destroy hook.
      }
    }
    await windowManager.destroy();
  }

  @override
  Future<void> setPreventClose(bool prevent) =>
      windowManager.setPreventClose(prevent);

  @override
  Future<void> setFullScreen(bool fullScreen) =>
      windowManager.setFullScreen(fullScreen);

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<bool> isMinimized() => windowManager.isMinimized();

  @override
  Future<Size> getSize() => windowManager.getSize();

  @override
  Future<Offset> getPosition() => windowManager.getPosition();

  @override
  Future<Display> getPrimaryDisplay() => screenRetriever.getPrimaryDisplay();

  @override
  Future<List<Display>> getAllDisplays() => screenRetriever.getAllDisplays();

  @override
  void addListener(WindowListener listener) =>
      windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);
}

final desktopWindowAdapterProvider = Provider<DesktopWindowAdapter>(
  (ref) => const WindowManagerAdapter(),
);
