import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'secure_resolver.dart';
import 'strict_http_client.dart';
import 'network_contracts.dart';

typedef NetworkClientFactory = http.Client Function(NetworkRoute route);

/// One shared policy owner for all native Pixiv HTTP exits. It owns the
/// revision, resolver, pooled route clients and diagnostics.
class NetworkAccessPolicy {
  NetworkAccessPolicy({
    PixivDestinationRegistry? registry,
    SecureResolver? resolver,
    NetworkDiagnostics? diagnostics,
    NetworkMode mode = NetworkMode.automatic,
    NetworkRevision revision = const NetworkRevision(0),
    NetworkClientFactory? clientFactory,
  }) : registry = registry ?? PixivDestinationRegistry(),
       _resolver = resolver ?? const SystemSecureResolver(),
       diagnostics = diagnostics ?? NetworkDiagnostics(),
       _mode = mode,
       _revision = revision,
       _clientFactory = clientFactory ?? const StrictHttpClientFactory().create;

  final PixivDestinationRegistry registry;
  final SecureResolver _resolver;
  final NetworkDiagnostics diagnostics;
  final NetworkClientFactory _clientFactory;
  final Map<String, http.Client> _clients = {};

  NetworkMode _mode;
  NetworkRevision _revision;
  bool _disposed = false;

  NetworkMode get mode => _mode;
  NetworkRevision get revision => _revision;

  /// Returns one pooled client for a route. The purpose is an explicit
  /// argument so call sites cannot accidentally construct an unscoped client,
  /// even though the native pool itself is keyed only by route/revision.
  http.Client clientFor(PixivDestinationPurpose purpose, NetworkRoute route) {
    _checkUsable();
    if (route.revision.value != _revision.value ||
        route.revision.networkIdentity != _revision.networkIdentity) {
      throw StateError('network route revision is stale');
    }
    return _clients.putIfAbsent(route.key, () => _clientFactory(route));
  }

  Future<ResolvedHost> resolve(
    PixivDestination destination, {
    NetworkCancelSignal? cancelSignal,
  }) async {
    _checkUsable();
    if (_mode == NetworkMode.directOnly) {
      throw const NetworkFailureException(NetworkFailureKind.connect);
    }
    final resolved = await _resolver.resolve(
      destination.canonicalHost,
      revision: _revision,
      cancelSignal: cancelSignal,
    );
    if (resolved.revision.value != _revision.value ||
        resolved.revision.networkIdentity != _revision.networkIdentity ||
        resolved.host != destination.canonicalHost) {
      throw const SecureResolutionException('stale or mismatched DNS result');
    }
    final safeAddresses = resolved.addresses
        .where(isPublicNetworkAddress)
        .toList(growable: false);
    if (safeAddresses.isEmpty) {
      throw const SecureResolutionException('no public DNS address');
    }
    return ResolvedHost(
      host: resolved.host,
      addresses: safeAddresses,
      dnsSource: resolved.dnsSource,
      revision: resolved.revision,
      ttl: resolved.ttl,
    );
  }

  /// Changes mode and invalidates all route pools. This is deliberately
  /// synchronous because `http.Client.close` is synchronous; no caller can
  /// issue another request through the old pool after this method returns.
  void setMode(NetworkMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _closeClients();
  }

  NetworkRevision advanceNetworkRevision({String? networkIdentity}) {
    _revision = NetworkRevision(
      _revision.value + 1,
      networkIdentity: networkIdentity ?? _revision.networkIdentity,
    );
    _closeClients();
    return _revision;
  }

  void recordFailure({
    required String host,
    required PixivDestinationPurpose purpose,
    required NetworkRoute route,
    required Object error,
    required Duration latency,
    String capability = 'baseline',
  }) {
    final failure = TransportFailureClassifier.classify(error);
    diagnostics.record(
      NetworkDiagnosticEvent(
        host: host,
        purpose: purpose,
        route: route.kind,
        ipFamily: route.ipFamily,
        dnsSource: route.dnsSource,
        failure: failure.kind,
        latency: latency,
        revision: route.revision,
        capability: capability,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _closeClients();
    await _resolver.dispose();
  }

  void _closeClients() {
    final clients = _clients.values.toList(growable: false);
    _clients.clear();
    for (final client in clients) {
      client.close();
    }
  }

  void _checkUsable() {
    if (_disposed) throw StateError('network policy is disposed');
  }
}

/// A policy-aware `package:http` client. The direct route is always tried
/// first. A second route is considered only for an empty GET/HEAD and an
/// eligible transport failure; HTTP, auth, cancellation, parse and TLS
/// failures are terminal and never replayed.
class PixivPolicyHttpClient extends http.BaseClient {
  PixivPolicyHttpClient({required this.policy, required this.purpose});

  final NetworkAccessPolicy policy;
  final PixivDestinationPurpose purpose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final destination = policy.registry.require(request.url, purpose);
    request.followRedirects = false;
    final direct = NetworkRoute.direct(policy.revision);
    final replay = _safeReplay(request);
    final cancelSignal = _RequestCancelSignal.from(request);
    final directTimer = Stopwatch()..start();
    try {
      return await _sendOnRoute(request, destination, direct);
    } on Object catch (error, stackTrace) {
      policy.recordFailure(
        host: destination.canonicalHost,
        purpose: purpose,
        route: direct,
        error: error,
        latency: directTimer.elapsed,
      );
      if (replay == null ||
          policy.mode == NetworkMode.directOnly ||
          (cancelSignal?.isCancelled ?? false) ||
          !TransportFailureClassifier.isFallbackEligible(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }

      final resolved = await policy.resolve(
        destination,
        cancelSignal: cancelSignal,
      );
      Object lastError = error;
      StackTrace lastStack = stackTrace;
      for (final address in resolved.addresses) {
        final route = NetworkRoute.secureDns(
          policy.revision,
          address,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
        final candidateTimer = Stopwatch()..start();
        try {
          if (cancelSignal?.isCancelled ?? false) {
            throw const NetworkFailureException(NetworkFailureKind.cancelled);
          }
          return await _sendOnRoute(replay, destination, route);
        } on Object catch (candidateError, candidateStack) {
          policy.recordFailure(
            host: destination.canonicalHost,
            purpose: purpose,
            route: route,
            error: candidateError,
            latency: candidateTimer.elapsed,
          );
          lastError = candidateError;
          lastStack = candidateStack;
          if (!TransportFailureClassifier.isFallbackEligible(candidateError)) {
            break;
          }
        }
      }
      Error.throwWithStackTrace(lastError, lastStack);
    }
  }

  Future<http.StreamedResponse> _sendOnRoute(
    http.BaseRequest request,
    PixivDestination destination,
    NetworkRoute route,
  ) async {
    final response = await policy.clientFor(purpose, route).send(request);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      await response.stream.drain<void>();
      throw NetworkRedirectException(response.statusCode);
    }
    return response;
  }

  static http.Request? _safeReplay(http.BaseRequest request) {
    if (request is! http.Request) return null;
    final method = request.method.toUpperCase();
    if ((method != 'GET' && method != 'HEAD') || request.bodyBytes.isNotEmpty) {
      return null;
    }
    final abortTrigger = request is http.AbortableRequest
        ? request.abortTrigger
        : null;
    return http.AbortableRequest(
        request.method,
        request.url,
        abortTrigger: abortTrigger,
      )
      ..headers.addAll(request.headers)
      ..followRedirects = false
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..bodyBytes = request.bodyBytes;
  }
}

class _RequestCancelSignal implements NetworkCancelSignal {
  _RequestCancelSignal(Future<void> trigger) {
    trigger.then<void>(
      (_) {
        _cancelled = true;
        if (!_completer.isCompleted) _completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        _cancelled = true;
        if (!_completer.isCompleted) _completer.complete();
      },
    );
  }

  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancel => _completer.future;

  static _RequestCancelSignal? from(http.BaseRequest request) {
    final trigger = request is http.AbortableRequest
        ? request.abortTrigger
        : null;
    return trigger == null ? null : _RequestCancelSignal(trigger);
  }
}

/// Shared app-scoped factory for API, OAuth, image cache and other strict
/// Pixiv HTTP consumers. The factory is the single place that can create a
/// policy client, making independent direct clients auditable.
class PixivNetworkFactory {
  PixivNetworkFactory(this.policy);

  final NetworkAccessPolicy policy;
  final Map<PixivDestinationPurpose, PixivPolicyHttpClient> _clients = {};
  CacheManager? _imageCacheManager;

  PixivPolicyHttpClient client(PixivDestinationPurpose purpose) {
    return _clients.putIfAbsent(
      purpose,
      () => PixivPolicyHttpClient(policy: policy, purpose: purpose),
    );
  }

  PixivPolicyHttpClient get apiClient => client(PixivDestinationPurpose.appApi);
  PixivPolicyHttpClient get oauthClient =>
      client(PixivDestinationPurpose.oauth);

  CacheManager get imageCacheManager {
    return _imageCacheManager ??= CacheManager(
      Config(
        'pixiv_func_images',
        fileService: HttpFileService(
          httpClient: client(PixivDestinationPurpose.image),
        ),
      ),
    );
  }

  Future<void> dispose() async {
    final cache = _imageCacheManager;
    _imageCacheManager = null;
    if (cache != null) {
      // flutter_cache_manager 3.4.x cannot close an as-yet-unopened JSON
      // repository. Opening it explicitly also makes provider-container
      // teardown deterministic in widget tests and during app shutdown.
      await cache.store.retrieveCacheData('pixiv_func_lifecycle_probe');
      await cache.dispose();
    }
    await policy.dispose();
  }
}
