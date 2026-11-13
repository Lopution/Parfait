import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log.dart';
import 'platform_caps.dart';

/// Method channel bridging native desktop window chrome, metrics, and controls.
const String kDesktopWindowChannelName = 'parfait/desktop_window';

/// Reports whether the current Linux session runs under Wayland.
bool detectLinuxWaylandFromEnv([Map<String, String>? env]) {
  final source = env ?? Platform.environment;
  final sessionType = source['XDG_SESSION_TYPE']?.trim().toLowerCase();
  if (sessionType == 'wayland') return true;
  if (sessionType == 'x11') return false;
  final waylandDisplay = source['WAYLAND_DISPLAY']?.trim();
  return waylandDisplay != null && waylandDisplay.isNotEmpty;
}

/// Snapshot of desktop host window metrics and frame configuration.
@immutable
class DesktopWindowPlatformMetrics {
  const DesktopWindowPlatformMetrics({
    this.isWayland = false,
    this.usesSystemTitleBar = true,
    this.isFullScreen = false,
    this.isMaximized = false,
    this.isActive = true,
    this.trafficLightWidth = 0,
    this.trafficLightHeight = 0,
    this.hoveredButton = '',
    this.pressedButton = '',
  });

  factory DesktopWindowPlatformMetrics.fromMap(Map<Object?, Object?> map) {
    return DesktopWindowPlatformMetrics(
      isWayland: _readBool(map['isWayland'], false),
      usesSystemTitleBar: _readBool(map['usesSystemTitleBar'], true),
      isFullScreen: _readBool(map['isFullScreen'], false),
      isMaximized: _readBool(map['isMaximized'], false),
      isActive: _readBool(map['isActive'], true),
      trafficLightWidth: _readDouble(map['trafficLightWidth'], 0),
      trafficLightHeight: _readDouble(map['trafficLightHeight'], 0),
      hoveredButton: _readString(map['hoveredButton']),
      pressedButton: _readString(map['pressedButton']),
    );
  }

  static const DesktopWindowPlatformMetrics fallback =
      DesktopWindowPlatformMetrics();

  final bool isWayland;
  final bool usesSystemTitleBar;
  final bool isFullScreen;
  final bool isMaximized;
  final bool isActive;
  final double trafficLightWidth;
  final double trafficLightHeight;
  final String hoveredButton;
  final String pressedButton;

  DesktopWindowPlatformMetrics copyWith({
    bool? isWayland,
    bool? usesSystemTitleBar,
    bool? isFullScreen,
    bool? isMaximized,
    bool? isActive,
    double? trafficLightWidth,
    double? trafficLightHeight,
    String? hoveredButton,
    String? pressedButton,
  }) {
    return DesktopWindowPlatformMetrics(
      isWayland: isWayland ?? this.isWayland,
      usesSystemTitleBar: usesSystemTitleBar ?? this.usesSystemTitleBar,
      isFullScreen: isFullScreen ?? this.isFullScreen,
      isMaximized: isMaximized ?? this.isMaximized,
      isActive: isActive ?? this.isActive,
      trafficLightWidth: trafficLightWidth ?? this.trafficLightWidth,
      trafficLightHeight: trafficLightHeight ?? this.trafficLightHeight,
      hoveredButton: hoveredButton ?? this.hoveredButton,
      pressedButton: pressedButton ?? this.pressedButton,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DesktopWindowPlatformMetrics &&
        other.isWayland == isWayland &&
        other.usesSystemTitleBar == usesSystemTitleBar &&
        other.isFullScreen == isFullScreen &&
        other.isMaximized == isMaximized &&
        other.isActive == isActive &&
        other.trafficLightWidth == trafficLightWidth &&
        other.trafficLightHeight == trafficLightHeight &&
        other.hoveredButton == hoveredButton &&
        other.pressedButton == pressedButton;
  }

  @override
  int get hashCode => Object.hash(
    isWayland,
    usesSystemTitleBar,
    isFullScreen,
    isMaximized,
    isActive,
    trafficLightWidth,
    trafficLightHeight,
    hoveredButton,
    pressedButton,
  );
}

/// Interactive region reported by Flutter to the native non-client hit tester.
@immutable
class DesktopTitleBarRegion {
  const DesktopTitleBarRegion({required this.rect, required this.kind});

  final Rect rect;

  /// `'caption'` for draggable empty title bar strip, `'maximize'` for the
  /// maximize/restore button (Windows 11 Snap Layouts `HTMAXBUTTON`).
  final String kind;

  List<Object> toWire() => <Object>[
    rect.left,
    rect.top,
    rect.right,
    rect.bottom,
    kind,
  ];
}

/// Native title-bar actions delegated to the OS window host.
enum DesktopWindowCommand {
  minimize,
  toggleMaximize,
  close,
  startDragging,
  titleBarDoubleClick,
  toggleFullScreen,
}

/// Port communicating with native desktop runner chrome hooks.
abstract class DesktopWindowHost {
  Future<DesktopWindowPlatformMetrics> getMetrics();

  Stream<DesktopWindowPlatformMetrics> get metricsStream;

  Future<void> setTitleBarMetrics({
    required List<DesktopTitleBarRegion> regions,
    double titleBarHeight = 0,
  });

  Future<void> performCommand(DesktopWindowCommand command);

  Future<void> dispose();
}

/// MethodChannel-backed [DesktopWindowHost] talking to Win32 / AppKit / GTK.
class MethodChannelDesktopWindowHost implements DesktopWindowHost {
  MethodChannelDesktopWindowHost({
    MethodChannel channel = const MethodChannel(kDesktopWindowChannelName),
    bool? isLinuxOverride,
    Map<String, String>? environmentOverride,
  }) : _channel = channel,
       _isLinuxOverride = isLinuxOverride,
       _environmentOverride = environmentOverride {
    _channel.setMethodCallHandler(_handleIncomingCall);
  }

  final MethodChannel _channel;
  final bool? _isLinuxOverride;
  final Map<String, String>? _environmentOverride;
  final StreamController<DesktopWindowPlatformMetrics> _controller =
      StreamController<DesktopWindowPlatformMetrics>.broadcast();

  bool get _isLinux => _isLinuxOverride ?? (!kIsWeb && Platform.isLinux);

  DesktopWindowPlatformMetrics _fallbackMetrics() =>
      DesktopWindowPlatformMetrics(
        isWayland: _isLinux && detectLinuxWaylandFromEnv(_environmentOverride),
        usesSystemTitleBar: true,
      );

  Future<void> _handleIncomingCall(MethodCall call) async {
    if (call.method != 'metricsChanged') return;
    final args = call.arguments;
    if (args is Map<Object?, Object?>) {
      _controller.add(DesktopWindowPlatformMetrics.fromMap(args));
    }
  }

  @override
  Stream<DesktopWindowPlatformMetrics> get metricsStream => _controller.stream;

  @override
  Future<DesktopWindowPlatformMetrics> getMetrics() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getMetrics',
      );
      if (raw == null) return _fallbackMetrics();
      return DesktopWindowPlatformMetrics.fromMap(raw);
    } on MissingPluginException {
      return _fallbackMetrics();
    } on PlatformException catch (error) {
      log('desktop_window getMetrics failed: $error');
      return _fallbackMetrics();
    }
  }

  @override
  Future<void> setTitleBarMetrics({
    required List<DesktopTitleBarRegion> regions,
    double titleBarHeight = 0,
  }) async {
    try {
      await _channel.invokeMethod<void>('setTitleBarMetrics', <String, Object>{
        'titleBarHeight': titleBarHeight,
        'regions': [for (final region in regions) region.toWire()],
      });
    } on MissingPluginException {
      // Unregistered in headless tests or non-desktop targets.
    } on PlatformException catch (error) {
      log('desktop_window setTitleBarMetrics failed: $error');
    }
  }

  @override
  Future<void> performCommand(DesktopWindowCommand command) async {
    try {
      await _channel.invokeMethod<void>(command.name);
    } on MissingPluginException {
      // Unregistered in headless tests or non-desktop targets.
    } on PlatformException catch (error) {
      log('desktop_window command(${command.name}) failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _controller.close();
  }
}

/// No-op [DesktopWindowHost] for mobile / web or headless unit tests.
class NoopDesktopWindowHost implements DesktopWindowHost {
  const NoopDesktopWindowHost({
    this.metrics = DesktopWindowPlatformMetrics.fallback,
  });

  final DesktopWindowPlatformMetrics metrics;

  @override
  Future<DesktopWindowPlatformMetrics> getMetrics() async => metrics;

  @override
  Stream<DesktopWindowPlatformMetrics> get metricsStream =>
      const Stream<DesktopWindowPlatformMetrics>.empty();

  @override
  Future<void> setTitleBarMetrics({
    required List<DesktopTitleBarRegion> regions,
    double titleBarHeight = 0,
  }) async {}

  @override
  Future<void> performCommand(DesktopWindowCommand command) async {}

  @override
  Future<void> dispose() async {}
}

final desktopWindowHostProvider = Provider<DesktopWindowHost>((ref) {
  final caps = ref.watch(platformCapsProvider);
  final host = caps.isDesktop
      ? MethodChannelDesktopWindowHost()
      : const NoopDesktopWindowHost();
  ref.onDispose(() => unawaited(host.dispose()));
  return host;
});

bool _readBool(Object? value, bool fallback) =>
    value is bool ? value : fallback;

double _readDouble(Object? value, double fallback) =>
    value is num && value.isFinite ? value.toDouble() : fallback;

String _readString(Object? value) => value is String ? value : '';
