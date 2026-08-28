import 'package:meta/meta.dart';

import '../../platform/android_platform_interfaces.dart';
import 'network_contracts.dart';

/// The WebView path remains ordinary direct navigation unless a platform
/// capability probe proves the AndroidX reverse-proxy contract. This policy
/// never starts a loopback listener on its own.
class WebViewRoutePolicy {
  WebViewRoutePolicy({
    required this.registry,
    required this.capabilities,
    this.loopbackImplementationAvailable = false,
    this.loopbackAdapter,
    NetworkRevision revision = const NetworkRevision(0),
    NetworkRevision Function()? revisionProvider,
    DateTime Function()? clock,
  }) : _revisionProvider = revisionProvider ?? (() => revision),
       _clock = clock ?? DateTime.now;

  final PixivDestinationRegistry registry;
  final WebKitCapabilities capabilities;

  /// This flag is intentionally false until a concrete adapter has passed
  /// platform and security validation. It is not a capability claim by itself.
  final bool loopbackImplementationAvailable;
  final WebViewLoopbackAdapter? loopbackAdapter;
  final NetworkRevision Function() _revisionProvider;
  final DateTime Function() _clock;
  int _activeLoopbackSessions = 0;

  /// Whether any live session currently owns a loopback listener.
  bool get listenerCreated => _activeLoopbackSessions > 0;

  NetworkRevision get currentRevision => _revisionProvider();

  void _listenerStarted() => _activeLoopbackSessions++;

  void _listenerStopped() {
    if (_activeLoopbackSessions > 0) _activeLoopbackSessions--;
  }

  /// Validates a URL for direct WebView navigation and reports whether the
  /// optional compatibility route is actually usable on this platform.
  Future<WebViewRouteDecision> probe(
    Uri uri, {
    PixivDestinationPurpose purpose = PixivDestinationPurpose.accountsWeb,
  }) async {
    final destination = registry.require(uri, purpose);
    final allowedHosts = registry.allowedHosts(purpose);
    WebViewCapabilityResult capability;
    try {
      final results = await Future.wait<bool>([
        capabilities.supportsProxyController,
        capabilities.supportsProxyReverseBypass,
        capabilities.supportsServiceWorkerController,
      ]);
      capability = WebViewCapabilityResult(
        proxyController: results[0],
        proxyReverseBypass: results[1],
        serviceWorkerController: results[2],
        implementationAvailable:
            loopbackAdapter != null && loopbackImplementationAvailable,
      );
    } on Object {
      // A platform probe failure is an explicit unsupported result. The
      // direct route remains available, while loopback cannot be guessed.
      capability = WebViewCapabilityResult(
        proxyController: false,
        proxyReverseBypass: false,
        serviceWorkerController: false,
        implementationAvailable: false,
        reason: 'AndroidX WebView capability probe failed',
      );
    }
    final available =
        capability.supported && capability.implementationAvailable;
    return WebViewRouteDecision(
      allowed: true,
      destination: destination,
      allowedHosts: allowedHosts,
      networkRevision: currentRevision,
      capability: capability,
      compatibilityModeAvailable: available,
      reason: available
          ? null
          : capability.reason ??
                'AndroidX WebView reverse-proxy capability is unavailable',
    );
  }

  void validateDirect(
    Uri uri, {
    PixivDestinationPurpose purpose = PixivDestinationPurpose.accountsWeb,
  }) {
    registry.require(uri, purpose);
  }
}

/// Explicit result of the AndroidX WebKit capability probe.
@immutable
class WebViewCapabilityResult {
  const WebViewCapabilityResult({
    required this.proxyController,
    required this.proxyReverseBypass,
    required this.serviceWorkerController,
    required this.implementationAvailable,
    this.reason,
  });

  final bool proxyController;
  final bool proxyReverseBypass;
  final bool serviceWorkerController;
  final bool implementationAvailable;
  final String? reason;

  bool get supported =>
      proxyController && proxyReverseBypass && serviceWorkerController;

  WebViewCapabilityStatus get status => supported
      ? WebViewCapabilityStatus.supported
      : WebViewCapabilityStatus.unsupported;
}

enum WebViewCapabilityStatus { supported, unsupported }

/// The only adapter that may create a compatibility listener. The product
/// currently supplies none; a future Android implementation must own strict
/// TLS/original-host routing and return a handle that is closed by the session.
abstract interface class WebViewLoopbackAdapter {
  Future<WebViewLoopbackHandle> open({
    required WebViewRouteSession session,
    required String ownerId,
  });
}

abstract interface class WebViewLoopbackHandle {
  Future<void> close();
}

enum WebViewRouteFailureCode {
  capabilityUnavailable,
  loopbackImplementationUnavailable,
  loopbackStartFailed,
  sessionClosed,
  staleNetworkRevision,
  invalidOwner,
  routeNotAllowed,
}

/// Typed boundary failure. It intentionally contains no URI, query, cookie,
/// credential or token so errors cannot become a secret logging sink.
class WebViewRouteFailure implements Exception {
  const WebViewRouteFailure(this.code, this.message, {this.cause});

  final WebViewRouteFailureCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'WebViewRouteFailure(${code.name})';
}

class WebViewCompatibilityException extends WebViewRouteFailure {
  const WebViewCompatibilityException()
    : super(
        WebViewRouteFailureCode.capabilityUnavailable,
        'AndroidX WebView compatibility route is unavailable',
      );
}

enum WebViewRouteInvalidationReason {
  background,
  pageDisposed,
  logout,
  authFailure,
  networkRevisionChanged,
}

enum WebViewRouteLifecycle { resumed, inactive, hidden, paused, detached }

/// Lifecycle handle for one direct or compatibility WebView route.
///
/// Every session captures the exact destination allowlist and network
/// revision at creation. Owners acquire leases; the final release closes the
/// loopback handle. Any invalidation closes all leases and is idempotent.
class WebViewRouteSession {
  WebViewRouteSession._({
    required this.policy,
    required this.uri,
    required this.purpose,
    required this.decision,
    required this.sessionId,
    required this.createdAt,
    this.accountId,
    required this.credentialRevision,
  });

  static int _sequence = 0;

  final WebViewRoutePolicy policy;
  final Uri uri;
  final PixivDestinationPurpose purpose;
  final WebViewRouteDecision decision;
  final String sessionId;
  final DateTime createdAt;
  final String? accountId;
  final int credentialRevision;
  final Map<String, int> _owners = {};
  WebViewLoopbackHandle? _loopbackHandle;
  Future<WebViewLoopbackHandle>? _loopbackOpening;
  bool _closed = false;
  DateTime? _closedAt;

  NetworkRevision get networkRevision => decision.networkRevision;
  Set<String> get allowedHosts => decision.allowedHosts;
  WebViewCapabilityResult get capability => decision.capability;
  bool get isClosed => _closed;
  bool get isStale => !_sameRevision(policy.currentRevision, networkRevision);
  DateTime? get closedAt => _closedAt;
  int get refCount => _owners.values.fold(0, (sum, count) => sum + count);

  static Future<WebViewRouteSession> open({
    required WebViewRoutePolicy policy,
    required Uri uri,
    PixivDestinationPurpose purpose = PixivDestinationPurpose.accountsWeb,
    bool requireCompatibility = false,
    String? accountId,
    int credentialRevision = 0,
  }) async {
    final decision = await policy.probe(uri, purpose: purpose);
    if (requireCompatibility && !decision.compatibilityModeAvailable) {
      throw const WebViewCompatibilityException();
    }
    final timestamp = policy._clock();
    return WebViewRouteSession._(
      policy: policy,
      uri: uri,
      purpose: purpose,
      decision: decision,
      sessionId: 'webview-${timestamp.microsecondsSinceEpoch}-${_sequence++}',
      createdAt: timestamp,
      accountId: accountId,
      credentialRevision: credentialRevision,
    );
  }

  /// Validates another navigation against this session's exact host set and
  /// captured network revision.
  void validate(Uri nextUri) {
    _ensureUsable();
    try {
      final destination = policy.registry.require(nextUri, purpose);
      if (!allowedHosts.contains(destination.canonicalHost)) {
        throw const WebViewRouteFailure(
          WebViewRouteFailureCode.routeNotAllowed,
          'WebView destination host is not allowed for this session',
        );
      }
    } on PixivDestinationException catch (error) {
      throw WebViewRouteFailure(
        WebViewRouteFailureCode.routeNotAllowed,
        'WebView destination is not allowed for this session',
        cause: error,
      );
    }
  }

  Future<WebViewRouteLease> acquire({required String ownerId}) async {
    _ensureUsable();
    _validateOwner(ownerId);
    _owners.update(ownerId, (count) => count + 1, ifAbsent: () => 1);
    return WebViewRouteLease._(this, ownerId);
  }

  /// Starts the optional loopback route only after the capability result,
  /// concrete adapter and this active session all agree. No route is created
  /// when any gate is absent.
  Future<WebViewRouteLease> openLoopback({required String ownerId}) async {
    _ensureUsable();
    if (!decision.compatibilityModeAvailable) {
      throw const WebViewRouteFailure(
        WebViewRouteFailureCode.capabilityUnavailable,
        'WebView compatibility capability is unavailable',
      );
    }
    final adapter = policy.loopbackAdapter;
    if (adapter == null || !policy.loopbackImplementationAvailable) {
      throw const WebViewRouteFailure(
        WebViewRouteFailureCode.loopbackImplementationUnavailable,
        'WebView loopback adapter is unavailable',
      );
    }
    final lease = await acquire(ownerId: ownerId);
    try {
      _ensureUsable();
      await _ensureLoopbackHandle(adapter, ownerId);
    } on Object catch (error) {
      await lease.release();
      if (error is WebViewRouteFailure) rethrow;
      throw WebViewRouteFailure(
        WebViewRouteFailureCode.loopbackStartFailed,
        'WebView loopback adapter failed to start',
        cause: error,
      );
    }
    return lease;
  }

  Future<void> _ensureLoopbackHandle(
    WebViewLoopbackAdapter adapter,
    String ownerId,
  ) async {
    if (_loopbackHandle != null) return;
    final opening = _loopbackOpening;
    if (opening != null) {
      await opening;
      return;
    }

    final future = _startLoopback(adapter, ownerId);
    _loopbackOpening = future;
    try {
      await future;
    } finally {
      if (identical(_loopbackOpening, future)) _loopbackOpening = null;
    }
  }

  Future<WebViewLoopbackHandle> _startLoopback(
    WebViewLoopbackAdapter adapter,
    String ownerId,
  ) async {
    final handle = await adapter.open(session: this, ownerId: ownerId);
    if (_closed) {
      try {
        await handle.close();
      } catch (error) {
        throw WebViewRouteFailure(
          WebViewRouteFailureCode.loopbackStartFailed,
          'WebView loopback handle failed to close after session shutdown',
          cause: error,
        );
      }
      throw const WebViewRouteFailure(
        WebViewRouteFailureCode.sessionClosed,
        'WebView route session is closed',
      );
    }
    _loopbackHandle = handle;
    policy._listenerStarted();
    return handle;
  }

  Future<void> _release(String ownerId) async {
    if (_closed) return;
    final count = _owners[ownerId];
    if (count == null) return;
    if (count == 1) {
      _owners.remove(ownerId);
    } else {
      _owners[ownerId] = count - 1;
    }
    if (refCount == 0) await _closeLoopback();
  }

  Future<void> invalidate(WebViewRouteInvalidationReason reason) => close();

  Future<void> onLifecycleChange(WebViewRouteLifecycle state) async {
    if (state != WebViewRouteLifecycle.resumed) {
      // The reason is retained by the caller's state/event log; cleanup is
      // intentionally the same for every non-foreground transition.
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _owners.clear();
    await _closeLoopback();
    _closedAt = policy._clock();
  }

  Future<void> _closeLoopback() async {
    final handle = _loopbackHandle;
    if (handle == null) return;
    _loopbackHandle = null;
    try {
      await handle.close();
    } finally {
      policy._listenerStopped();
    }
  }

  void _ensureUsable() {
    if (_closed) {
      throw const WebViewRouteFailure(
        WebViewRouteFailureCode.sessionClosed,
        'WebView route session is closed',
      );
    }
    if (isStale) {
      throw const WebViewRouteFailure(
        WebViewRouteFailureCode.staleNetworkRevision,
        'WebView route session has a stale network revision',
      );
    }
  }

  static void _validateOwner(String ownerId) {
    if (ownerId.trim().isEmpty || ownerId.length > 128) {
      throw const WebViewRouteFailure(
        WebViewRouteFailureCode.invalidOwner,
        'WebView route owner is invalid',
      );
    }
  }

  static bool _sameRevision(NetworkRevision left, NetworkRevision right) {
    return left.value == right.value &&
        left.networkIdentity == right.networkIdentity;
  }
}

/// One reference-counted owner lease. Releasing is idempotent so page dispose,
/// lifecycle cleanup and error cleanup can safely converge.
class WebViewRouteLease {
  WebViewRouteLease._(this._session, this.ownerId);

  final WebViewRouteSession _session;
  final String ownerId;
  bool _released = false;

  bool get isReleased => _released;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _session._release(ownerId);
  }
}

@immutable
class WebViewRouteDecision {
  const WebViewRouteDecision({
    required this.allowed,
    required this.destination,
    required this.allowedHosts,
    required this.networkRevision,
    required this.capability,
    required this.compatibilityModeAvailable,
    this.reason,
  });

  final bool allowed;
  final PixivDestination destination;
  final Set<String> allowedHosts;
  final NetworkRevision networkRevision;
  final WebViewCapabilityResult capability;
  final bool compatibilityModeAvailable;
  final String? reason;
}

/// Default production capability implementation before the Android channel
/// is registered. It is explicit direct-only behavior, not a fake success.
class UnsupportedWebKitCapabilities implements WebKitCapabilities {
  const UnsupportedWebKitCapabilities();

  @override
  Future<bool> get supportsProxyController async => false;

  @override
  Future<bool> get supportsProxyReverseBypass async => false;

  @override
  Future<bool> get supportsServiceWorkerController async => false;
}
