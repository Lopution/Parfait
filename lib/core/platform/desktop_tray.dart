import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log.dart';
import 'platform_caps.dart';

/// Method channel managing native desktop system tray icon and menu.
const String kTrayChannelName = 'parfait/tray';

/// Actions triggered by the user clicking the system tray icon or menu.
enum TrayAction { showWindow, openDownloads, quit }

/// Localized menu item and tooltip strings sent from Flutter to the tray host.
@immutable
class TrayMenuLabels {
  const TrayMenuLabels({
    required this.tooltip,
    required this.showWindow,
    required this.downloads,
    required this.quit,
  });

  final String tooltip;
  final String showWindow;
  final String downloads;
  final String quit;

  Map<String, String> toMap() => <String, String>{
    'tooltip': tooltip,
    'showWindow': showWindow,
    'downloads': downloads,
    'quit': quit,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TrayMenuLabels &&
        other.tooltip == tooltip &&
        other.showWindow == showWindow &&
        other.downloads == downloads &&
        other.quit == quit;
  }

  @override
  int get hashCode => Object.hash(tooltip, showWindow, downloads, quit);
}

/// Platform interface for desktop system tray integration.
abstract class TrayPort {
  Future<bool> isSupported();

  Future<void> initialize({required TrayMenuLabels labels});

  Future<void> updateLabels(TrayMenuLabels labels);

  Stream<TrayAction> get actions;

  Future<void> dispose();
}

/// MethodChannel-backed [TrayPort] talking to Win32 / NSStatusBar / AppIndicator.
class MethodChannelTrayPort implements TrayPort {
  MethodChannelTrayPort({
    MethodChannel channel = const MethodChannel(kTrayChannelName),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handleIncomingCall);
  }

  final MethodChannel _channel;
  final StreamController<TrayAction> _actions =
      StreamController<TrayAction>.broadcast();
  bool? _supportedCache;

  Future<void> _handleIncomingCall(MethodCall call) async {
    if (call.method != 'onTrayAction') return;
    final raw = call.arguments;
    final action = switch (raw) {
      'showWindow' => TrayAction.showWindow,
      'openDownloads' => TrayAction.openDownloads,
      'quit' => TrayAction.quit,
      _ => null,
    };
    if (action != null && !_actions.isClosed) {
      _actions.add(action);
    }
  }

  @override
  Stream<TrayAction> get actions => _actions.stream;

  @override
  Future<bool> isSupported() async {
    if (_supportedCache != null) return _supportedCache!;
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      return _supportedCache = supported ?? false;
    } on MissingPluginException {
      return _supportedCache = false;
    } on PlatformException catch (error) {
      log('tray isSupported failed: $error');
      return _supportedCache = false;
    }
  }

  @override
  Future<void> initialize({required TrayMenuLabels labels}) async {
    if (!await isSupported()) return;
    try {
      await _channel.invokeMethod<void>('initialize', labels.toMap());
    } on MissingPluginException {
      _supportedCache = false;
    } on PlatformException catch (error) {
      log('tray initialize failed: $error');
    }
  }

  @override
  Future<void> updateLabels(TrayMenuLabels labels) async {
    if (!await isSupported()) return;
    try {
      await _channel.invokeMethod<void>('updateLabels', labels.toMap());
    } on MissingPluginException {
      _supportedCache = false;
    } on PlatformException catch (error) {
      log('tray updateLabels failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      // Unregistered in headless tests or non-desktop targets.
    } on PlatformException catch (error) {
      log('tray dispose failed: $error');
    }
    await _actions.close();
  }
}

/// Safe fallback [TrayPort] when system tray is unsupported or unavailable.
class NoopTrayPort implements TrayPort {
  const NoopTrayPort();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> initialize({required TrayMenuLabels labels}) async {}

  @override
  Future<void> updateLabels(TrayMenuLabels labels) async {}

  @override
  Stream<TrayAction> get actions => const Stream<TrayAction>.empty();

  @override
  Future<void> dispose() async {}
}

final trayPortProvider = Provider<TrayPort>((ref) {
  final caps = ref.watch(platformCapsProvider);
  final port = caps.isDesktop ? MethodChannelTrayPort() : const NoopTrayPort();
  ref.onDispose(() => unawaited(port.dispose()));
  return port;
});
