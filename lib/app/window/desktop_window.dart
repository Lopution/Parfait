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

import '../../core/image/image_worker_providers.dart';
import '../../core/log.dart';
import '../../core/network/data_worker.dart';
import '../../core/platform/desktop_tray.dart';
import '../../core/platform/desktop_window_channel.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/settings/settings_repository.dart';
import '../../l10n/app_localizations.dart';
import 'desktop_title_bar.dart';
import 'desktop_window_adapter.dart';
import 'window_geometry.dart';

export 'desktop_window_adapter.dart';

DesktopWindowPlatformMetrics _preparedDesktopMetrics =
    DesktopWindowPlatformMetrics.fallback;

/// Prepares the desktop window before `runApp`: restores the saved place on
/// its work area (or the default place on a first launch) and sizes the
/// window before the runner shows it on its first frame, so no frame paints
/// at the runner's phone-shaped default and then jumps.
///
/// On Wayland, window positioning is skipped because compositors reject or
/// misreport global window coordinates.
Future<void> prepareDesktopWindow({
  DesktopWindowAdapter adapter = const WindowManagerAdapter(),
  DesktopWindowHost? host,
  SettingsRepository? settingsRepository,
  bool? supportedOverride,
}) async {
  if (!(supportedOverride ?? desktopWindowSupported)) return;
  await adapter.ensureInitialized();
  final resolvedHost = host ?? MethodChannelDesktopWindowHost();
  final ownsHost = host == null;
  late final DesktopWindowPlatformMetrics metrics;
  try {
    metrics = await resolvedHost.getMetrics();
  } finally {
    if (ownsHost) unawaited(resolvedHost.dispose());
  }
  _preparedDesktopMetrics = metrics;

  final settings = await _readSettings(settingsRepository);
  final geometry = await _restoreGeometry(
    settings,
    adapter: adapter,
    isWayland: metrics.isWayland,
  );
  await adapter.setMinimumSize(minimumWindowSize);
  await adapter.setSize(geometry.size);
  if (!metrics.isWayland && geometry.position != null) {
    await adapter.setPosition(geometry.position!);
  }
  await adapter.setPreventClose(true);
  if (settings.windowMaximized) await adapter.maximize();
}

Future<AppSettings> _readSettings(SettingsRepository? repository) async {
  try {
    final repo =
        repository ??
        PreferencesSettingsRepository(preferences: SharedPreferencesAsync());
    return await repo.load();
  } on Object catch (error) {
    log('window: settings unreadable, opening at the default place: $error');
    return AppSettings.defaults();
  }
}

Future<RestoredWindowGeometry> _restoreGeometry(
  AppSettings settings, {
  required DesktopWindowAdapter adapter,
  required bool isWayland,
}) async {
  final Rect primaryArea;
  final List<Rect> areas;
  try {
    final primary = await adapter.getPrimaryDisplay();
    primaryArea = _workAreaOf(primary);
    areas = [
      for (final display in await adapter.getAllDisplays())
        _workAreaOf(display),
    ];
  } on Object catch (error) {
    log('window: displays unreadable, opening at the default place: $error');
    return resolveWindowGeometry(
      width: settings.windowWidth,
      height: settings.windowHeight,
      x: settings.windowX,
      y: settings.windowY,
      maximized: settings.windowMaximized,
      primaryArea: const Rect.fromLTWH(0, 0, 1440, 900),
      workAreas: const [],
      isWayland: isWayland,
    );
  }
  return resolveWindowGeometry(
    width: settings.windowWidth,
    height: settings.windowHeight,
    x: settings.windowX,
    y: settings.windowY,
    maximized: settings.windowMaximized,
    primaryArea: primaryArea,
    workAreas: areas,
    isWayland: isWayland,
  );
}

Rect _workAreaOf(Display display) => workAreaOf(
  size: display.size,
  visiblePosition: display.visiblePosition,
  visibleSize: display.visibleSize,
);

/// Coordinates desktop window geometry persistence, Wayland safety, close-to-tray
/// lifecycle, native chrome metrics, and tray menu actions.
class DesktopWindowSession with WindowListener {
  DesktopWindowSession({
    required DesktopWindowAdapter adapter,
    required DesktopWindowHost host,
    required TrayPort trayPort,
    required bool Function() readCloseToTray,
    required ({double? width, double? height, double? x, double? y}) Function()
    readSavedPlace,
    required SaveWindowGeometryCallback saveGeometry,
    this.onOpenDownloads,
    this.onBeforeDestroy,
    DesktopWindowPlatformMetrics? initialMetrics,
    TargetPlatform? platformOverride,
  }) : _adapter = adapter,
       _host = host,
       _trayPort = trayPort,
       _readCloseToTray = readCloseToTray,
       _readSavedPlace = readSavedPlace,
       _saveGeometry = saveGeometry,
       _platformOverride = platformOverride,
       metrics = ValueNotifier<DesktopWindowPlatformMetrics>(
         initialMetrics ?? DesktopWindowPlatformMetrics.fallback,
       );

  static const _saveDelay = Duration(milliseconds: 400);
  static const _closeSaveTimeout = Duration(seconds: 2);
  static const _beforeDestroyTimeout = Duration(milliseconds: 500);

  final DesktopWindowAdapter _adapter;
  final DesktopWindowHost _host;
  final TrayPort _trayPort;
  final bool Function() _readCloseToTray;
  final ({double? width, double? height, double? x, double? y}) Function()
  _readSavedPlace;
  final SaveWindowGeometryCallback _saveGeometry;
  final VoidCallback? onOpenDownloads;
  final Future<void> Function()? onBeforeDestroy;
  final TargetPlatform? _platformOverride;

  TargetPlatform get _platform => _platformOverride ?? defaultTargetPlatform;

  final ValueNotifier<DesktopWindowPlatformMetrics> metrics;

  Timer? _saveTimer;
  StreamSubscription<DesktopWindowPlatformMetrics>? _metricsSub;
  StreamSubscription<TrayAction>? _traySub;
  Size? _ordinarySize;
  Offset? _ordinaryPosition;
  bool _closingInProgress = false;
  bool _disposed = false;
  bool _trayInitialized = false;
  bool _trayInitializing = false;
  TrayMenuLabels? _desiredLabels;
  TrayMenuLabels? _appliedLabels;

  Future<void> attach({required TrayMenuLabels initialLabels}) async {
    _adapter.addListener(this);
    _metricsSub = _host.metricsStream.listen(_applyHostMetrics);
    _traySub = _trayPort.actions.listen(_handleTrayAction);
    _host.setApplicationShouldTerminateHandler(prepareForApplicationTerminate);
    _desiredLabels ??= initialLabels;

    try {
      await _adapter.setPreventClose(true);
    } on Object catch (error) {
      log('window: setPreventClose failed: $error');
    }

    try {
      _applyHostMetrics(await _host.getMetrics());
    } on Object catch (error) {
      log('window: host getMetrics failed: $error');
    }

    if (!_disposed) {
      await _initTray();
    }
    if (!_disposed) {
      await captureOrdinary();
    }
  }

  Future<void> _initTray() async {
    if (_trayInitialized || _trayInitializing || _disposed) return;
    _trayInitializing = true;
    try {
      if (await _trayPort.isSupported() && !_disposed) {
        final initial = _desiredLabels;
        if (initial == null) return;
        await _trayPort.initialize(labels: initial);
        _appliedLabels = initial;
        _trayInitialized = true;
        // Flush any localization update that arrived while initialize() ran.
        while (!_disposed &&
            _desiredLabels != null &&
            _desiredLabels != _appliedLabels) {
          final latest = _desiredLabels!;
          _appliedLabels = latest;
          await _trayPort.updateLabels(latest);
        }
      }
    } on Object catch (error) {
      log('tray: initialize failed: $error');
    } finally {
      _trayInitializing = false;
    }
  }

  Future<void> updateTrayLabels(TrayMenuLabels labels) async {
    if (_disposed || _desiredLabels == labels) return;
    _desiredLabels = labels;
    if (!_trayInitialized || _appliedLabels == labels) return;
    _appliedLabels = labels;
    try {
      await _trayPort.updateLabels(labels);
    } on Object catch (error) {
      log('tray: updateLabels failed: $error');
    }
  }

  void _applyHostMetrics(DesktopWindowPlatformMetrics next) {
    if (_disposed) return;
    if (metrics.value != next) {
      metrics.value = next;
    }
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(saveNow()));
  }

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowResized() {
    if (_disposed) return;
    unawaited(captureOrdinary());
    _scheduleSave();
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowMoved() {
    if (_disposed) return;
    unawaited(captureOrdinary());
    _scheduleSave();
  }

  @override
  void onWindowMaximize() {
    _applyHostMetrics(metrics.value.copyWith(isMaximized: true));
    _scheduleSave();
  }

  @override
  void onWindowUnmaximize() {
    _applyHostMetrics(metrics.value.copyWith(isMaximized: false));
    _scheduleSave();
  }

  @override
  void onWindowEnterFullScreen() {
    _applyHostMetrics(metrics.value.copyWith(isFullScreen: true));
  }

  @override
  void onWindowLeaveFullScreen() {
    _applyHostMetrics(metrics.value.copyWith(isFullScreen: false));
    _scheduleSave();
  }

  @override
  void onWindowFocus() {
    _applyHostMetrics(metrics.value.copyWith(isActive: true));
  }

  @override
  void onWindowBlur() {
    _applyHostMetrics(metrics.value.copyWith(isActive: false));
  }

  @override
  void onWindowClose() {
    unawaited(handleWindowClose());
  }

  /// Flushes pending window geometry and runs [onBeforeDestroy] when the OS
  /// initiates application-level termination (e.g. macOS `Cmd+Q` or Dock Quit),
  /// always bypassing close-to-tray so termination is never cancelled.
  Future<void> prepareForApplicationTerminate() async {
    if (_disposed) return;
    final inflight = _terminateFuture;
    if (inflight != null) return inflight;
    final future = _runApplicationTerminateFlush();
    _terminateFuture = future;
    try {
      await future;
    } finally {
      if (identical(_terminateFuture, future)) {
        _terminateFuture = null;
      }
    }
  }

  Future<void>? _terminateFuture;

  Future<void> _runApplicationTerminateFlush() async {
    _saveTimer?.cancel();
    try {
      await saveNow().timeout(_closeSaveTimeout);
    } on TimeoutException {
      log('window: saveNow timed out during application terminate');
    } on Object catch (error) {
      log('window: saveNow failed during application terminate: $error');
    }
    if (onBeforeDestroy case final cleanup?) {
      try {
        await cleanup().timeout(_beforeDestroyTimeout);
      } on Object catch (error) {
        log('window: beforeDestroy cleanup failed during terminate: $error');
      }
    }
  }

  /// Handles close requests with close-to-tray check and flush-before-destroy.
  Future<void> handleWindowClose({bool forceQuit = false}) async {
    if (_disposed || _closingInProgress) return;
    _saveTimer?.cancel();
    _closingInProgress = true;
    try {
      final hideForMacDock = !forceQuit && _platform == TargetPlatform.macOS;
      final closeToTray =
          !forceQuit &&
          !hideForMacDock &&
          _readCloseToTray() &&
          await _trayPort.isSupported();
      try {
        await saveNow().timeout(_closeSaveTimeout);
      } on TimeoutException {
        log('window: saveNow timed out during close');
      }
      if (hideForMacDock) {
        if (await _adapter.isFullScreen()) {
          await _adapter.setFullScreen(false);
        }
        await _adapter.hide();
        return;
      }
      if (closeToTray) {
        await _adapter.hide();
        return;
      }
      if (onBeforeDestroy case final cleanup?) {
        try {
          await cleanup().timeout(_beforeDestroyTimeout);
        } on Object catch (error) {
          log('window: beforeDestroy cleanup failed: $error');
        }
      }
      await _adapter.setPreventClose(false);
      await _adapter.destroy();
    } on Object catch (error) {
      log('window: close failed: $error');
      if (!forceQuit && _readCloseToTray() && await _trayPort.isSupported()) {
        return;
      }
      try {
        await _adapter.setPreventClose(false);
        await _adapter.destroy();
      } on Object catch (fallbackError) {
        log('window: destroy fallback failed: $fallbackError');
      }
    } finally {
      _closingInProgress = false;
    }
  }

  Future<void> _handleTrayAction(TrayAction action) async {
    switch (action) {
      case TrayAction.showWindow:
        await restoreWindow();
      case TrayAction.openDownloads:
        await restoreWindow();
        onOpenDownloads?.call();
      case TrayAction.quit:
        await handleWindowClose(forceQuit: true);
    }
  }

  Future<void> restoreWindow() async {
    try {
      if (await _adapter.isMinimized()) {
        await _adapter.restore();
      }
    } on Object catch (error) {
      log('window: restore failed: $error');
    }
    try {
      await _adapter.show();
    } on Object catch (error) {
      log('window: show failed: $error');
    }
    try {
      await _adapter.focus();
    } on Object catch (error) {
      log('window: focus failed: $error');
    }
  }

  Future<void> minimize() async {
    try {
      await _adapter.minimize();
    } on Object catch (error) {
      log('window: minimize failed: $error');
    }
  }

  Future<void> toggleMaximize() async {
    try {
      if (await _adapter.isMaximized()) {
        await _adapter.unmaximize();
      } else {
        await _adapter.maximize();
      }
    } on Object catch (error) {
      log('window: toggleMaximize failed: $error');
    }
  }

  Future<void> requestClose() async {
    try {
      await _adapter.close();
    } on Object catch (error) {
      log('window: close request failed: $error');
      await handleWindowClose();
    }
  }

  Future<void> toggleFullScreen() async {
    try {
      if (!metrics.value.isFullScreen) {
        await captureOrdinary();
        _saveTimer?.cancel();
      }
      if (!metrics.value.usesSystemTitleBar) {
        await _host.performCommand(DesktopWindowCommand.toggleFullScreen);
      } else {
        final current =
            metrics.value.isFullScreen || await _adapter.isFullScreen();
        await _adapter.setFullScreen(!current);
        _applyHostMetrics(metrics.value.copyWith(isFullScreen: !current));
      }
    } on Object catch (error) {
      log('window: toggleFullScreen failed: $error');
    }
  }

  Future<void> startDragging() =>
      _host.performCommand(DesktopWindowCommand.startDragging);

  Future<void> titleBarDoubleClick() =>
      _host.performCommand(DesktopWindowCommand.titleBarDoubleClick);

  Future<void> restoreEditMenu() =>
      _host.performCommand(DesktopWindowCommand.restoreEditMenu);

  Future<void> updateTitleBarRegions(
    List<DesktopTitleBarRegion> regions, {
    double? titleBarHeight,
  }) => _host.setTitleBarMetrics(
    regions: regions,
    titleBarHeight: metrics.value.isFullScreen ? 0.0 : (titleBarHeight ?? 32.0),
  );

  static bool _isValidOrdinarySize(Size size) =>
      size.width >= 200 && size.height >= 100;

  static bool _isValidOrdinaryPosition(Offset position) =>
      position.dx > -30000 && position.dy > -30000;

  /// Captures pre-maximize ordinary bounds; each plugin call is isolated so
  /// a Wayland position failure never discards window size. Minimized windows
  /// report Win32 iconic sentinel coordinates (`-32000`, `160x28`) and are
  /// skipped.
  Future<void> captureOrdinary() async {
    if (metrics.value.isFullScreen) return;
    final fullScreen = await _readFullScreen();
    if (fullScreen == true) return;
    final minimized = await _readMinimized();
    if (minimized == true) return;
    final maximized = await _readMaximized();
    if (maximized == true) return;

    final size = await _readSize();
    final position = metrics.value.isWayland ? null : await _readPosition();
    if (size != null && _isValidOrdinarySize(size)) _ordinarySize = size;
    if (position != null && _isValidOrdinaryPosition(position)) {
      _ordinaryPosition = position;
    }
  }

  /// Persists the window's ordinary size/position and maximized state.
  Future<void> saveNow() async {
    if (metrics.value.isFullScreen) return;
    final fullScreen = await _readFullScreen();
    if (fullScreen == true) return;

    final saved = _readSavedPlace();
    final minimized = await _readMinimized() ?? false;
    final maximized = minimized
        ? metrics.value.isMaximized
        : (await _readMaximized() ?? metrics.value.isMaximized);
    final rawSize = minimized ? null : await _readSize();
    final rawPosition = minimized || metrics.value.isWayland
        ? null
        : await _readPosition();
    final size = rawSize != null && _isValidOrdinarySize(rawSize)
        ? rawSize
        : null;
    final position =
        rawPosition != null && _isValidOrdinaryPosition(rawPosition)
        ? rawPosition
        : null;

    if (!maximized && !minimized) {
      if (size != null) _ordinarySize = size;
      if (position != null) _ordinaryPosition = position;
    }

    final preserveOrdinary = maximized || minimized;
    final effectiveWidth = preserveOrdinary
        ? (_ordinarySize?.width ?? saved.width ?? size?.width)
        : (size?.width ?? _ordinarySize?.width ?? saved.width);
    final effectiveHeight = preserveOrdinary
        ? (_ordinarySize?.height ?? saved.height ?? size?.height)
        : (size?.height ?? _ordinarySize?.height ?? saved.height);
    final effectiveX = preserveOrdinary
        ? (_ordinaryPosition?.dx ?? saved.x ?? position?.dx)
        : (position?.dx ?? _ordinaryPosition?.dx ?? saved.x);
    final effectiveY = preserveOrdinary
        ? (_ordinaryPosition?.dy ?? saved.y ?? position?.dy)
        : (position?.dy ?? _ordinaryPosition?.dy ?? saved.y);

    try {
      await _saveGeometry(
        width: effectiveWidth,
        height: effectiveHeight,
        x: effectiveX,
        y: effectiveY,
        maximized: maximized,
      );
    } on Object catch (error) {
      log('window: could not save the place: $error');
    }
  }

  Future<bool?> _readMinimized() async {
    try {
      return await _adapter.isMinimized();
    } on Object catch (error) {
      log('window: isMinimized failed: $error');
      return null;
    }
  }

  Future<bool?> _readFullScreen() async {
    try {
      return await _adapter.isFullScreen();
    } on Object catch (error) {
      log('window: isFullScreen failed: $error');
      return null;
    }
  }

  Future<bool?> _readMaximized() async {
    try {
      return await _adapter.isMaximized();
    } on Object catch (error) {
      log('window: isMaximized failed: $error');
      return null;
    }
  }

  Future<Size?> _readSize() async {
    try {
      return await _adapter.getSize();
    } on Object catch (error) {
      log('window: getSize failed: $error');
      return null;
    }
  }

  Future<Offset?> _readPosition() async {
    try {
      return await _adapter.getPosition();
    } on Object catch (error) {
      log('window: getPosition failed: $error');
      return null;
    }
  }

  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _host.setApplicationShouldTerminateHandler(null);
    _adapter.removeListener(this);
    unawaited(_metricsSub?.cancel());
    unawaited(_traySub?.cancel());
    metrics.dispose();
  }
}

/// Binds desktop window persistence, close-to-tray handling, custom chrome
/// metrics, and tray menu actions to the running app lifecycle.
class DesktopWindowBinding extends ConsumerStatefulWidget {
  const DesktopWindowBinding({
    required this.child,
    this.onOpenDownloads,
    super.key,
  });

  final Widget child;
  final VoidCallback? onOpenDownloads;

  @override
  ConsumerState<DesktopWindowBinding> createState() =>
      _DesktopWindowBindingState();
}

class _DesktopWindowBindingState extends ConsumerState<DesktopWindowBinding> {
  DesktopWindowSession? _session;
  DesktopWindowActions? _actions;

  TrayMenuLabels _labelsFor(BuildContext context) {
    final l10n = Localizations.of<AppLocalizations>(context, AppLocalizations);
    if (l10n == null) {
      return const TrayMenuLabels(
        tooltip: 'Parfait',
        showWindow: 'Show Window',
        downloads: 'Downloads',
        quit: 'Quit',
      );
    }
    return TrayMenuLabels(
      tooltip: 'Parfait',
      showWindow: l10n.trayShowWindow,
      downloads: l10n.trayDownloads,
      quit: l10n.trayQuit,
    );
  }

  @override
  void initState() {
    super.initState();
    if (!desktopWindowSupported) return;
    final adapter = ref.read(desktopWindowAdapterProvider);
    final host = ref.read(desktopWindowHostProvider);
    final trayPort = ref.read(trayPortProvider);
    final session = DesktopWindowSession(
      adapter: adapter,
      host: host,
      trayPort: trayPort,
      initialMetrics: _preparedDesktopMetrics,
      readCloseToTray: () =>
          ref.read(settingsProvider).value?.closeToTray ?? false,
      readSavedPlace: () {
        final settings = ref.read(settingsProvider).value;
        return (
          width: settings?.windowWidth,
          height: settings?.windowHeight,
          x: settings?.windowX,
          y: settings?.windowY,
        );
      },
      saveGeometry: ({width, height, x, y, required maximized}) => ref
          .read(settingsProvider.notifier)
          .setWindowGeometry(
            width: width,
            height: height,
            x: x,
            y: y,
            maximized: maximized,
          ),
      onOpenDownloads: widget.onOpenDownloads,
      onBeforeDestroy: () async {
        if (!mounted) return;
        final container = ProviderScope.containerOf(context, listen: false);
        final tasks = <Future<void>>[];
        if (container.read(imageWorkerProvider.exists)) {
          tasks.add(container.read(imageWorkerProvider).dispose());
        }
        if (container.read(dataWorkerProvider.exists)) {
          tasks.add(container.read(dataWorkerProvider).close());
        }
        if (tasks.isNotEmpty) {
          await Future.wait(tasks);
        }
      },
    );
    _session = session;
    _actions = DesktopWindowActions(
      onMinimize: () => unawaited(session.minimize()),
      onToggleMaximize: () => unawaited(session.toggleMaximize()),
      onClose: () => unawaited(session.requestClose()),
      onToggleFullScreen: () => unawaited(session.toggleFullScreen()),
      onStartDragging: () => unawaited(session.startDragging()),
      onTitleBarDoubleClick: () => unawaited(session.titleBarDoubleClick()),
      onRegionsChanged: (regions) =>
          unawaited(session.updateTitleBarRegions(regions)),
      onRegionsWithHeightChanged: (regions, height) => unawaited(
        session.updateTitleBarRegions(regions, titleBarHeight: height),
      ),
      onRestoreEditMenu: () => unawaited(session.restoreEditMenu()),
    );
    unawaited(
      session.attach(
        initialLabels: const TrayMenuLabels(
          tooltip: 'Parfait',
          showWindow: 'Show Window',
          downloads: 'Downloads',
          quit: 'Quit',
        ),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = _session;
    if (session != null) {
      unawaited(session.updateTrayLabels(_labelsFor(context)));
    }
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final actions = _actions;
    if (session == null || actions == null) {
      return widget.child;
    }
    return DesktopWindowScope(
      metrics: session.metrics,
      actions: actions,
      child: widget.child,
    );
  }
}
