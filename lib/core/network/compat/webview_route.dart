import 'package:meta/meta.dart';

import '../../platform/android_platform_interfaces.dart';
import 'network_contracts.dart';

/// The WebView path remains ordinary direct navigation unless a platform
/// capability probe proves the AndroidX reverse-proxy contract. This class
/// never starts a loopback listener on its own.
class WebViewRoutePolicy {
  WebViewRoutePolicy({
    required this.registry,
    required this.capabilities,
    this.loopbackImplementationAvailable = false,
  });

  final PixivDestinationRegistry registry;
  final WebKitCapabilities capabilities;
  final bool loopbackImplementationAvailable;

  bool listenerCreated = false;

  /// Validates a URL for direct WebView navigation and reports whether the
  /// optional compatibility route is actually usable on this platform.
  Future<WebViewRouteDecision> probe(
    Uri uri, {
    PixivDestinationPurpose purpose = PixivDestinationPurpose.accountsWeb,
  }) async {
    registry.require(uri, purpose);
    final proxyController = await capabilities.supportsProxyController;
    final serviceWorker = await capabilities.supportsServiceWorkerController;
    final available =
        loopbackImplementationAvailable && proxyController && serviceWorker;
    return WebViewRouteDecision(
      allowed: true,
      compatibilityModeAvailable: available,
      reason: available
          ? null
          : 'AndroidX WebView reverse-proxy capability is unavailable',
    );
  }

  void validateDirect(
    Uri uri, {
    PixivDestinationPurpose purpose = PixivDestinationPurpose.accountsWeb,
  }) {
    registry.require(uri, purpose);
  }
}

/// Lifecycle handle for a WebView route. In the current product graph only
/// the validated direct route is available; requesting the optional loopback
/// route fails closed before any listener is bound.
class WebViewRouteSession {
  WebViewRouteSession._({required this.uri, required this.decision});

  final Uri uri;
  final WebViewRouteDecision decision;
  bool _closed = false;

  bool get isClosed => _closed;

  static Future<WebViewRouteSession> open({
    required WebViewRoutePolicy policy,
    required Uri uri,
    PixivDestinationPurpose purpose = PixivDestinationPurpose.accountsWeb,
    bool requireCompatibility = false,
  }) async {
    final decision = await policy.probe(uri, purpose: purpose);
    if (requireCompatibility && !decision.compatibilityModeAvailable) {
      throw const WebViewCompatibilityException();
    }
    return WebViewRouteSession._(uri: uri, decision: decision);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
  }
}

class WebViewCompatibilityException implements Exception {
  const WebViewCompatibilityException();

  @override
  String toString() => 'WebViewCompatibilityException: capability unavailable';
}

@immutable
class WebViewRouteDecision {
  const WebViewRouteDecision({
    required this.allowed,
    required this.compatibilityModeAvailable,
    this.reason,
  });

  final bool allowed;
  final bool compatibilityModeAvailable;
  final String? reason;
}

class UnsupportedWebKitCapabilities implements WebKitCapabilities {
  const UnsupportedWebKitCapabilities();

  @override
  Future<bool> get supportsProxyController async => false;

  @override
  Future<bool> get supportsServiceWorkerController async => false;
}
