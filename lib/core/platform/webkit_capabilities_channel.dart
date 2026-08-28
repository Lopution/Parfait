import 'package:flutter/services.dart';

import 'android_platform_interfaces.dart';

/// AndroidX WebKit feature probe. A channel error remains an error at the
/// WebView route policy, which maps it to a visible/direct-only capability
/// result rather than assuming support.
abstract final class WebKitCapabilityMethods {
  static const channel = 'pixivfunc/webkit_capabilities';
  static const probe = 'probe';
}

class MethodChannelWebKitCapabilities implements WebKitCapabilities {
  MethodChannelWebKitCapabilities([
    this._channel = const MethodChannel(WebKitCapabilityMethods.channel),
  ]);

  final MethodChannel _channel;
  Future<Map<String, Object?>>? _probeFuture;

  Future<Map<String, Object?>> _probe() {
    return _probeFuture ??= _readProbe();
  }

  Future<Map<String, Object?>> _readProbe() async {
    final raw = await _channel.invokeMethod<Object?>(
      WebKitCapabilityMethods.probe,
    );
    if (raw is! Map) {
      throw const WebKitCapabilityChannelException(
        'capability probe returned a malformed payload',
      );
    }
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) {
        throw const WebKitCapabilityChannelException(
          'capability probe returned a malformed key',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  Future<bool> _readBool(String key) async {
    final value = (await _probe())[key];
    if (value is! bool) {
      throw WebKitCapabilityChannelException(
        'capability probe field $key is malformed',
      );
    }
    return value;
  }

  @override
  Future<bool> get supportsProxyController => _readBool('proxyController');

  @override
  Future<bool> get supportsProxyReverseBypass =>
      _readBool('proxyReverseBypass');

  @override
  Future<bool> get supportsServiceWorkerController =>
      _readBool('serviceWorkerController');
}

class WebKitCapabilityChannelException implements Exception {
  const WebKitCapabilityChannelException(this.message);

  final String message;

  @override
  String toString() => 'WebKitCapabilityChannelException: $message';
}
