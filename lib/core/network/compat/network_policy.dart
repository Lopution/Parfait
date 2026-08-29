import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'secure_resolver.dart';
import 'strict_http_client.dart';
import 'network_contracts.dart';

typedef NetworkClientFactory = http.Client Function(NetworkRoute route);

/// One shared policy owner for all native Pixiv HTTP exits. It owns the
/// revision, resolver, pooled route clients, per-host route memory and
/// diagnostics.
class NetworkAccessPolicy {
  NetworkAccessPolicy({
    PixivDestinationRegistry? registry,
    SecureResolver? resolver,
    NetworkDiagnostics? diagnostics,
    NetworkMode mode = NetworkMode.automatic,
    NetworkRevision revision = const NetworkRevision(0),
    NetworkClientFactory? clientFactory,
    List<String> dohEndpoints = const [
      // Cloudflare DoH over its well-known anycast IPs (PixEz-proven
      // bootstrap: `1dot1dot1dot1.cloudflare-dns.com` + static IP map).
      // Anycast serves these endpoints on any Cloudflare IP, so no system
      // DNS round trip and no resolver recursion is needed before the first
      // query; the endpoint certificate still carries the real hostname so
      // hostname verification is unchanged.
      //
      // Order = preference. Mainland users see polluted answers from
      // mainland DoH (AliDNSPod also poison *.pixiv.net), so those are NOT
      // defaults — they remain available via the setting override.
      'https://1dot1dot1dot1.cloudflare-dns.com/dns-query',
      'https://dns.google/dns-query',
    ],
    Map<String, List<InternetAddress>>? dohHostOverrides,
  }) : registry = registry ?? PixivDestinationRegistry(),
       _resolver =
           resolver ??
           (dohEndpoints.isEmpty
               ? const SystemSecureResolver()
               : DohResolver(
                   endpointUrls: dohEndpoints,
                   hostOverrides: dohHostOverrides ?? _defaultDohHostOverrides,
                 )),
       diagnostics = diagnostics ?? NetworkDiagnostics(),
       _mode = mode,
       _revision = revision,
       _clientFactory =
           clientFactory ?? const StrictHttpClientFactory().create;

  /// Cloudflare DoH endpoints' anycast IPs (same values PixEz pins; the
  /// DNS names themselves are only used for SNI/Host — the TCP peer is
  /// always one of these).
  /// Cloudflare DoH endpoints' anycast IPs (same values PixEz pins; the
  /// DNS names themselves are only used for SNI/Host — the TCP peer is
  /// always one of these). `InternetAddress` has no const constructor, so
  /// the map is built lazily.
  static Map<String, List<InternetAddress>> get _defaultDohHostOverrides => {
    '1dot1dot1dot1.cloudflare-dns.com': [
      InternetAddress('104.16.248.249'),
      InternetAddress('104.16.249.249'),
    ],
    'cloudflare-dns.com': [
      InternetAddress('104.16.248.249'),
      InternetAddress('104.16.249.249'),
    ],
    'dns.google': [
      InternetAddress('8.8.8.8'),
      InternetAddress('8.8.4.4'),
    ],
  };

  final PixivDestinationRegistry registry;
  final SecureResolver _resolver;
  final NetworkDiagnostics diagnostics;
  final NetworkClientFactory _clientFactory;
  final Map<String, http.Client> _clients = {};

  /// The strict-tier resolver (DoH by default, system when DoH is off).
  /// Exposed for the probe page; production requests use [runLadder].
  SecureResolver get resolver => _resolver;

  /// Per-host route memory: a host that reached a success through the strict
  /// (secure-DNS) tier is remembered so subsequent requests skip the doomed
  /// direct attempt inside the wall. Bounded, TTL'd, and cleared with the
  /// same events that close route pools (mode/revision changes).
  final Map<String, _HostRouteMemory> _routeMemory = {};
  static const int _maxRouteMemoryEntries = 32;

  NetworkMode _mode;
  NetworkRevision _revision;
  bool _disposed = false;

  NetworkMode get mode => _mode;
  NetworkRevision get revision => _revision;

  /// Whether [host] is currently remembered as strict-only. Exposed for
  /// tests; production callers go through [runLadder].
  @visibleForTesting
  bool hasStrictRouteMemory(String host, {DateTime? now}) =>
      _routeMemory[host]?.isFresh(now ?? DateTime.now()) ?? false;

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

  /// The single route ladder shared by the API and download exits.
  ///
  /// [attempt] performs one request on the given route and returns the
  /// response; [canReplay] gates whether a *second* attempt is permitted at
  /// all (empty GET/HEAD only — a body must never be re-sent after a failed
  /// first attempt). The ladder:
  ///
  /// 1. Direct route — always attempted unless route memory says the host
  ///    is strict-only (inside the wall the direct attempt costs a timeout
  ///    every single request).
  /// 2. On an eligible transport failure, resolve via the policy resolver
  ///    (DoH by default) and try each candidate address on the secure-DNS
  ///    route.
  ///
  /// Failures are classified and recorded in diagnostics; a non-eligible
  /// failure (certificate mismatch, auth, cancellation, HTTP…) aborts the
  /// ladder immediately and rethrows.
  Future<T> runLadder<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required bool canReplay,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
  }) async {
    _checkUsable();
    final host = destination.canonicalHost;
    final now = DateTime.now();

    var directRoute = NetworkRoute.direct(_revision);
    if (_routeMemory[host]?.isFresh(now) ?? false) {
      // Inside the wall the direct attempt is known to fail; jump straight
      // to the strict tier.
      directRoute = NetworkRoute.secureDns(
        _revision,
        _routeMemory[host]!.address,
        dnsSource: _routeMemory[host]!.dnsSource,
        ttl: _routeMemory[host]!.ttl,
      );
    }

    final directTimer = Stopwatch()..start();
    try {
      final result = await attempt(directRoute, destination.uri);
      // A success on the direct route clears a stale strict memory entry
      // (e.g. the user moved to an open network).
      _routeMemory.remove(host);
      return result;
    } on Object catch (error, stackTrace) {
      policyRecord(destination, directRoute, error, directTimer.elapsed);
      if (_mode == NetworkMode.directOnly ||
          (cancelSignal?.isCancelled ?? false) ||
          !canReplay ||
          !TransportFailureClassifier.isFallbackEligible(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }

      final resolved = await resolve(destination, cancelSignal: cancelSignal);
      Object lastError = error;
      StackTrace lastStack = stackTrace;
      for (final address in resolved.addresses) {
        final route = NetworkRoute.secureDns(
          _revision,
          address,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
        final candidateTimer = Stopwatch()..start();
        try {
          if (cancelSignal?.isCancelled ?? false) {
            throw const NetworkFailureException(NetworkFailureKind.cancelled);
          }
          final result = await attempt(route, destination.uri);
          _routeMemory[host] = _HostRouteMemory(
            address,
            dnsSource: resolved.dnsSource,
            ttl: resolved.ttl,
            createdAt: DateTime.now(),
          );
          _trimRouteMemory();
          return result;
        } on Object catch (candidateError, candidateStack) {
          policyRecord(destination, route, candidateError, candidateTimer.elapsed);
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

  /// Records a failure; kept as a method so the ladder and diagnostics stay
  /// in one place (route memory and client pools are owned here).
  void policyRecord(
    PixivDestination destination,
    NetworkRoute route,
    Object error,
    Duration latency,
  ) {
    recordFailure(
      host: destination.canonicalHost,
      purpose: destination.purpose,
      route: route,
      error: error,
      latency: latency,
    );
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

  /// Changes mode and invalidates all route pools and route memory. This is
  /// deliberately synchronous because `http.Client.close` is synchronous; no
  /// caller can issue another request through the old pool after this method
  /// returns.
  void setMode(NetworkMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _closeClients();
    _routeMemory.clear();
  }

  NetworkRevision advanceNetworkRevision({String? networkIdentity}) {
    _revision = NetworkRevision(
      _revision.value + 1,
      networkIdentity: networkIdentity ?? _revision.networkIdentity,
    );
    _closeClients();
    _routeMemory.clear();
    return _revision;
  }

  void _trimRouteMemory() {
    if (_routeMemory.length <= _maxRouteMemoryEntries) return;
    final oldest = _routeMemory.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry in oldest.take(_routeMemory.length - _maxRouteMemoryEntries)) {
      _routeMemory.remove(entry.key);
    }
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

class _HostRouteMemory {
  _HostRouteMemory(
    this.address, {
    required this.dnsSource,
    required this.ttl,
    required this.createdAt,
  });

  final InternetAddress address;
  final DnsSource dnsSource;
  final Duration ttl;
  final DateTime createdAt;

  bool isFresh(DateTime now) => now.difference(createdAt) < _kRouteMemoryTtl;
}

const _kRouteMemoryTtl = Duration(minutes: 10);

/// A policy-aware `package:http` client. The direct route is always tried
/// first (unless route memory says strict-only). A second route is
/// considered only for an empty GET/HEAD and an eligible transport failure;
/// HTTP, auth, cancellation, parse and TLS certificate failures are
/// terminal and never replayed.
class PixivPolicyHttpClient extends http.BaseClient {
  PixivPolicyHttpClient({required this.policy, required this.purpose});

  final NetworkAccessPolicy policy;
  final PixivDestinationPurpose purpose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final destination = policy.registry.require(request.url, purpose);
    request.followRedirects = false;
    final replay = _safeReplay(request);
    final cancelSignal = _RequestCancelSignal.from(request);
    return policy.runLadder<http.StreamedResponse>(
      destination: destination,
      cancelSignal: cancelSignal,
      canReplay: replay != null,
      attempt: (route, url) async {
        final response = await policy.clientFor(purpose, route).send(
          replay ?? request,
        );
        if (response.statusCode >= 300 && response.statusCode < 400) {
          await response.stream.drain<void>();
          throw NetworkRedirectException(response.statusCode);
        }
        return response;
      },
    );
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