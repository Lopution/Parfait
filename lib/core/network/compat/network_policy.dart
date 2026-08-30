import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'secure_resolver.dart';
import 'network_contracts.dart';
import 'rhttp_client_factory.dart';

/// Builds the transport client for one route.
///
/// [purpose] is part of the signature because the time budget depends on it:
/// image and download exits stream an unbounded body and must not carry a
/// total request timeout, while API/OAuth exits must (see
/// [RhttpClientFactory.timeoutsFor]).
typedef NetworkClientFactory = http.Client Function(
  NetworkRoute route,
  String canonicalHost,
  PixivDestinationPurpose purpose,
);

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
    this.echFrontHost = 'cloudflare-ech.com',
    this.insecureNoSniEnabled = false,
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
           clientFactory ?? RhttpClientFactory.create;

  /// ECH front host used to fetch the ECH config (Cloudflare serves the
  /// ECH config for pixiv domains via this host; configurable in settings).
  final String echFrontHost;

  /// Whether the user explicitly enabled the `insecureNoSni` fallback tier
  /// (PRD R6). Default false; never auto-enabled by probe failures.
  final bool insecureNoSniEnabled;

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

  /// Whether [host] is currently remembered as non-direct (strict tier).
  /// Exposed for tests; production callers go through [runLadder].
  @visibleForTesting
  bool hasStrictRouteMemory(String host, {DateTime? now}) =>
      (_routeMemory[host]?.isFresh(now ?? DateTime.now()) ?? false) &&
      _routeMemory[host]!.kind != NetworkRouteKind.direct;

  /// The remembered route kind for [host], or null when absent/stale.
  @visibleForTesting
  NetworkRouteKind? rememberedRouteKind(String host, {DateTime? now}) {
    final memory = _routeMemory[host];
    if (memory == null || !memory.isFresh(now ?? DateTime.now())) return null;
    return memory.kind;
  }

  /// Returns one pooled client for a route. The purpose and canonical host
  /// are explicit arguments so call sites cannot accidentally construct an
  /// unscoped client; the native pool is keyed by route + host + purpose
  /// because rhttp's DNS override is per-host and its time budget is
  /// per-purpose.
  http.Client clientFor(
    PixivDestinationPurpose purpose,
    NetworkRoute route,
    String canonicalHost,
  ) {
    _checkUsable();
    if (route.revision.value != _revision.value ||
        route.revision.networkIdentity != _revision.networkIdentity) {
      throw StateError('network route revision is stale');
    }
    final key = '${route.key}|$canonicalHost|${purpose.name}';
    return _clients.putIfAbsent(
      key,
      () => _clientFactory(route, canonicalHost, purpose),
    );
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
  /// The single route ladder shared by the API and download exits.
  ///
  /// [attempt] performs one request on the given route and returns the
  /// response; [canReplay] gates whether a *second* attempt is permitted at
  /// all (empty GET/HEAD only — a body must never be re-sent after a failed
  /// first attempt). The ladder:
  ///
  /// 1. Direct route — always attempted unless route memory says the host
  ///    skips it (inside the wall the direct attempt costs a timeout every
  ///    single request).
  /// 2. On an eligible transport failure, the destination group's tier
  ///    order applies:
  ///    - API / OAuth / accounts / www (Cloudflare):
  ///      `ech → dohRealSni`
  ///    - images / downloads (*.pximg.net origin):
  ///      `dohRealSni → noSni`
  ///    - `insecureNoSni` is appended ONLY when the user explicitly
  ///      enabled it (`insecureNoSniEnabled`); it is never automatic.
  ///
  /// Each tier resolves its own address via [resolve] (DoH) unless the
  /// route memory already knows a working tier for the host; memory is
  /// keyed by host and remembers the tier (not just an IP), so the next
  /// request starts at the remembered tier.
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

    // Start at the remembered tier (if fresh); otherwise direct.
    final memory = _routeMemory[host];
    var firstRoute = NetworkRoute.direct(_revision);
    if (memory != null && memory.isFresh(now)) {
      firstRoute = memory.routeFor(_revision);
    }

    final firstTimer = Stopwatch()..start();
    try {
      final result = await attempt(firstRoute, destination.uri);
      // A success clears stale memory (e.g. the user moved to an open
      // network).
      _routeMemory.remove(host);
      return result;
    } on Object catch (error, stackTrace) {
      policyRecord(destination, firstRoute, error, firstTimer.elapsed);
      if (_mode == NetworkMode.directOnly ||
          (cancelSignal?.isCancelled ?? false) ||
          !canReplay ||
          !TransportFailureClassifier.isFallbackEligible(error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }

      // Determine the ordered fallback tiers for this destination.
      final tiers = _fallbackTiersFor(destination.purpose);
      Object lastError = error;
      StackTrace lastStack = stackTrace;

      // The destination resolve is lazy and memoised: only tiers that
      // actually need the destination host's address pay for it. The ECH
      // tier does not — it connects to the ECH front's anycast address —
      // so a slow or failing DoH lookup must not take it down with it.
      ResolvedHost? pendingResolved;
      Future<ResolvedHost> resolveOnce() async =>
          pendingResolved ??= await resolve(
            destination,
            cancelSignal: cancelSignal,
          );

      for (final kind in tiers) {
        final NetworkRoute? route;
        try {
          route = await _routeForTier(
            kind,
            destination,
            resolveHost: resolveOnce,
            cancelSignal: cancelSignal,
          );
        } on Object catch (routeError, routeStack) {
          // Building this tier failed (DoH down, ECH config unavailable…).
          // That makes this one tier unusable, not the whole ladder: the
          // remaining tiers may not depend on the same input. Cancellation
          // is the exception — it aborts everything.
          lastError = routeError;
          lastStack = routeStack;
          if (routeError is NetworkFailureException &&
              routeError.kind == NetworkFailureKind.cancelled) {
            Error.throwWithStackTrace(routeError, routeStack);
          }
          continue;
        }
        if (route == null) {
          // Tier unavailable (e.g. ECH config could not be fetched): skip
          // it and continue with the next tier.
          continue;
        }
        final candidateTimer = Stopwatch()..start();
        try {
          if (cancelSignal?.isCancelled ?? false) {
            throw const NetworkFailureException(NetworkFailureKind.cancelled);
          }
          final result = await attempt(route, destination.uri);
          _routeMemory[host] = _HostRouteMemory(
            route.address!,
            kind: route.kind,
            dnsSource: route.dnsSource,
            ttl: route.ttl ?? _kRouteMemoryTtl,
            createdAt: DateTime.now(),
            echConfig: route.echConfig,
          );
          _trimRouteMemory();
          return result;
        } on Object catch (candidateError, candidateStack) {
          policyRecord(
            destination,
            route,
            candidateError,
            candidateTimer.elapsed,
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

  /// Ordered fallback tiers after a direct failure, per destination group.
  /// [insecureNoSni] is appended only when the user explicitly enabled it.
  List<NetworkRouteKind> _fallbackTiersFor(PixivDestinationPurpose purpose) {
    final isCloudflareHost = switch (purpose) {
      PixivDestinationPurpose.appApi ||
      PixivDestinationPurpose.oauth ||
      PixivDestinationPurpose.accountsWeb ||
      PixivDestinationPurpose.pixivWeb => true,
      PixivDestinationPurpose.image => false,
    };
    final tiers = isCloudflareHost
        ? [NetworkRouteKind.ech, NetworkRouteKind.dohRealSni]
        : [NetworkRouteKind.dohRealSni, NetworkRouteKind.noSni];
    if (insecureNoSniEnabled) {
      tiers.add(NetworkRouteKind.insecureNoSni);
    }
    return tiers;
  }

  /// Builds a [NetworkRoute] for [kind], resolving the destination host only
  /// for the tiers that need it.
  ///
  /// [resolveHost] is lazy and memoised by the caller: the ECH tier never
  /// calls it. Returns null when the tier cannot be constructed (e.g. the ECH
  /// config lookup failed, or the policy was injected with a non-DoH
  /// resolver). The ladder skips null tiers and falls through to the next one
  /// — an unavailable ECH tier never turns into a hard error here, because
  /// the caller treats "no route" as "tier unavailable".
  Future<NetworkRoute?> _routeForTier(
    NetworkRouteKind kind,
    PixivDestination destination, {
    required Future<ResolvedHost> Function() resolveHost,
    required NetworkCancelSignal? cancelSignal,
  }) async {
    switch (kind) {
      case NetworkRouteKind.ech:
        // Deliberately does NOT resolve the destination host. The ECH tier's
        // TCP peer is the ECH front's anycast address (ipv4hint from the
        // front's own HTTPS RR); the destination's mainland answer is
        // polluted and would send the handshake nowhere. Coupling this tier
        // to the destination resolve also meant a slow or failing DoH lookup
        // took ECH down with it, which is exactly what kept the tier from
        // ever running on a mainland device.
        final ech = await _lookupEchConfig(cancelSignal: cancelSignal);
        if (ech == null) return null;
        final frontAddress = ech.frontAddresses.isNotEmpty
            ? ech.frontAddresses.first
            : await _resolveFrontHost(cancelSignal: cancelSignal);
        if (frontAddress == null) return null;
        return NetworkRoute.ech(
          _revision,
          frontAddress,
          ech.echConfig,
          dnsSource: DnsSource.doh,
          ttl: ech.ttl,
        );
      case NetworkRouteKind.dohRealSni:
        final resolved = await resolveHost();
        return NetworkRoute.secureDns(
          _revision,
          resolved.addresses.first,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
      case NetworkRouteKind.noSni:
        final resolved = await resolveHost();
        return NetworkRoute.noSni(
          _revision,
          resolved.addresses.first,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
      case NetworkRouteKind.insecureNoSni:
        final resolved = await resolveHost();
        return NetworkRoute.insecureNoSni(
          _revision,
          resolved.addresses.first,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
      case NetworkRouteKind.direct:
        throw StateError('direct is not a fallback tier');
    }
  }

  /// Fetches the ECH config for [echFrontHost]. Returns null when the
  /// resolver is not a DoH resolver or the lookup failed — the ECH tier is
  /// then treated as unavailable and the ladder moves on (never a silent
  /// plain-TLS downgrade: the next tier, if any, is its own explicit
  /// route).
  Future<EchConfigResult?> _lookupEchConfig({
    required NetworkCancelSignal? cancelSignal,
  }) async {
    final resolver = _resolver;
    if (resolver is! DohResolver) {
      return null;
    }
    try {
      return await resolver.lookupEchConfig(
        echFrontHost,
        revision: _revision,
        cancelSignal: cancelSignal,
      );
    } on Object {
      return null;
    }
  }

  /// Resolves the ECH front host (e.g. cloudflare-ech.com) to a connect
  /// address when its HTTPS RR carries no ipv4hint. The front host is not
  /// polluted by the GFW (its answers stayed clean in mainland probes), so
  /// the DoH resolve is the fallback source for the ECH TCP peer.
  Future<InternetAddress?> _resolveFrontHost({
    required NetworkCancelSignal? cancelSignal,
  }) async {
    final resolver = _resolver;
    if (resolver is! DohResolver) return null;
    try {
      final resolved = await resolver.resolve(
        echFrontHost,
        revision: _revision,
        cancelSignal: cancelSignal,
      );
      return resolved.addresses.isEmpty ? null : resolved.addresses.first;
    } on Object {
      return null;
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
    required this.kind,
    required this.dnsSource,
    required this.ttl,
    required this.createdAt,
    this.echConfig,
  });

  final InternetAddress address;
  final NetworkRouteKind kind;
  final DnsSource dnsSource;
  final Duration ttl;
  final DateTime createdAt;
  final List<int>? echConfig;

  bool isFresh(DateTime now) => now.difference(createdAt) < _kRouteMemoryTtl;

  /// Rebuilds the route at the [revision] seen by [NetworkRoute.kind].
  NetworkRoute routeFor(NetworkRevision revision) => NetworkRoute.remembered(
    revision,
    kind,
    address,
    dnsSource: dnsSource,
    ttl: ttl,
    echConfig: echConfig,
  );
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
        final response = await policy
            .clientFor(purpose, route, destination.canonicalHost)
            .send(
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