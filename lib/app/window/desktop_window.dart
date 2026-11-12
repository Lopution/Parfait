// window_manager 0.6 and screen_retriever 0.3 rebuild on nativeapi, whose
// Linux build hook needs the GTK 3, X11 and Xi development packages even
// for `flutter test`. The 0.5.x/0.2.x line is the same API over plain
// platform plugins, so every checkout and CI image keeps running without
// extra system packages; revisit when that line stops being published.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/log.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/settings_repository.dart';
import 'window_geometry.dart';

/// Whether the desktop window API applies on this platform. Phones and the
/// web keep their single window.
bool get desktopWindowSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Prepares the desktop window before `runApp`: initializes the plugin,
/// restores the saved place on its work area (or the default place on a
/// first launch) and only then shows the window, so no frame paints at the
/// phone-shaped runner default and then jumps.
///
/// A setting that cannot be read opens the default place; the failure is
/// logged, never hidden behind a made-up success.
Future<void> prepareDesktopWindow() async {
  if (!desktopWindowSupported) return;
  await windowManager.ensureInitialized();
  final settings = await _readSettings();
  final geometry = await _restoreGeometry(settings);
  final options = WindowOptions(
    size: geometry.size,
    minimumSize: minimumWindowSize,
    center: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setMinimumSize(minimumWindowSize);
    await windowManager.setSize(geometry.size);
    await windowManager.setPosition(geometry.position);
    if (settings.windowMaximized) await windowManager.maximize();
    await windowManager.show();
    await windowManager.focus();
  });
}

Future<AppSettings> _readSettings() async {
  try {
    return await PreferencesSettingsRepository(
      preferences: SharedPreferencesAsync(),
    ).load();
  } on Object catch (error) {
    log('window: settings unreadable, opening at the default place: $error');
    return AppSettings.defaults();
  }
}

Future<WindowGeometry> _restoreGeometry(AppSettings settings) async {
  final Rect primaryArea;
  final List<Rect> areas;
  try {
    final primary = await screenRetriever.getPrimaryDisplay();
    primaryArea = _workAreaOf(primary);
    areas = [
      for (final display in await screenRetriever.getAllDisplays())
        _workAreaOf(display),
    ];
  } on Object catch (error) {
    log('window: displays unreadable, opening at the default place: $error');
    return defaultWindowGeometry(Rect.fromLTWH(0, 0, 1440, 900));
  }
  final width = settings.windowWidth;
  final height = settings.windowHeight;
  final x = settings.windowX;
  final y = settings.windowY;
  if (width == null || height == null || x == null || y == null) {
    return defaultWindowGeometry(primaryArea);
  }
  final saved = WindowGeometry(
    size: Size(width, height),
    position: Offset(x, y),
    maximized: settings.windowMaximized,
  );
  // The display the window last lived on, or the primary one when that
  // display is gone (unplugged, rearranged).
  return fitToWorkArea(saved, workAreaFor(saved, areas) ?? primaryArea);
}

Rect _workAreaOf(Display display) => workAreaOf(
  size: display.size,
  visiblePosition: display.visiblePosition,
  visibleSize: display.visibleSize,
);

/// Saves the desktop window's place after it moves, resizes or is
/// maximized/unmaximized, debounced so a drag writes once.
///
/// A maximized window keeps the ordinary place it had before: the size and
/// position stored are the pre-maximize ones, so unmaximizing after a
/// restart lands where the user left it. A full-screen player is skipped.
class DesktopWindowBinding extends ConsumerStatefulWidget {
  const DesktopWindowBinding({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DesktopWindowBinding> createState() =>
      _DesktopWindowBindingState();
}

class _DesktopWindowBindingState extends ConsumerState<DesktopWindowBinding>
    with WindowListener {
  static const _saveDelay = Duration(milliseconds: 400);

  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    if (!desktopWindowSupported) return;
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (desktopWindowSupported) windowManager.removeListener(this);
    _saveTimer?.cancel();
    super.dispose();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_save()));
  }

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  Future<void> _save() async {
    try {
      if (await windowManager.isFullScreen()) return;
      final maximized = await windowManager.isMaximized();
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();
      final place = maximized
          ? _ordinaryPlace(size, position)
          : WindowGeometry(size: size, position: position);
      await ref
          .read(settingsProvider.notifier)
          .setWindowGeometry(
            width: place.size.width,
            height: place.size.height,
            x: place.position.dx,
            y: place.position.dy,
            maximized: maximized,
          );
    } on Object catch (error) {
      log('window: could not save the place: $error');
    }
  }

  /// The place to keep under a maximized window: the last saved ordinary
  /// one, or the current size when nothing was saved yet.
  WindowGeometry _ordinaryPlace(Size fallbackSize, Offset fallbackPosition) {
    final settings = ref.read(settingsProvider).value;
    final width = settings?.windowWidth;
    final height = settings?.windowHeight;
    final x = settings?.windowX;
    final y = settings?.windowY;
    if (width != null && height != null && x != null && y != null) {
      return WindowGeometry(size: Size(width, height), position: Offset(x, y));
    }
    return WindowGeometry(size: fallbackSize, position: fallbackPosition);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
