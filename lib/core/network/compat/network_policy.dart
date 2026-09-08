import 'dart:async';
import 'dart:io';

import '../pixiv_client_identity.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'secure_resolver.dart';
import 'network_contracts.dart';
import 'network_fast_route_store.dart';
import 'rhttp_client_factory.dart';
import '../rhttp_gate.dart';

/// Builds the transport client for one route.
///
/// [purpose] is part of the signature because the time budget depends on it:
/// image and download exits stream an unbounded body and must not carry a
/// total request timeout, while API/OAuth exits must (see
/// [RhttpClientFactory.timeoutsFor]).
typedef NetworkClientFactory =
    http.Client Function(
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
    this.fastRouteStore,
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
    List<String> echDoHEndpoints = const [
      // PixEz queries the ECH config through Alibaba DNS
      // (`lookup_alidns_https_ech`): reachable inside the wall, and
      // `cloudflare-ech.com` HTTPS RR answers are not poisoned there (only
      // *.pixiv.net A records are). Cloudflare anycast stays as fallback.
      'https://dns.alidns.com/dns-query',
      'https://1dot1dot1dot1.cloudflare-dns.com/dns-query',
    ],
    this.clock = DateTime.now,
  }) : registry = registry ?? PixivDestinationRegistry(),
       _resolver =
           resolver ??
           (dohEndpoints.isEmpty
               ? const SystemSecureResolver()
               : DohResolver(
                   endpointUrls: dohEndpoints,
                   hostOverrides: dohHostOverrides ?? _defaultDohHostOverrides,
                   echEndpointUrls: echDoHEndpoints,
                 )),
       diagnostics = diagnostics ?? NetworkDiagnostics(),
       _mode = mode,
       _revision = revision,
       _clientFactory = clientFactory ?? RhttpClientFactory.create;

  /// ECH front host used to fetch the ECH config (Cloudflare serves the
  /// ECH config for pixiv domains via this host; configurable in settings).
  final String echFrontHost;

  /// Whether the user explicitly enabled the `insecureNoSni` fallback tier
  /// (PRD R6). In production this is enabled only together with
  /// [fastRouteStore], which makes it PixEz's persisted compatibility tier;
  /// tests and standalone callers retain the old opt-in fallback behavior.
  final bool insecureNoSniEnabled;

  /// Persisted PixEz-compatible host addresses. When present, the
  /// compatibility tier is attempted before the cold direct probe and does
  /// not need a DNS lookup or a HEAD request.
  final PixivFastRouteStore? fastRouteStore;

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
    'dns.google': [InternetAddress('8.8.8.8'), InternetAddress('8.8.4.4')],
    'dns.alidns.com': [
      InternetAddress('223.5.5.5'),
      InternetAddress('223.6.6.6'),
    ],
  };

  final PixivDestinationRegistry registry;
  final SecureResolver _resolver;
  final NetworkDiagnostics diagnostics;
  final NetworkClientFactory _clientFactory;
  final Map<String, http.Client> _clients = {};

  /// Injectable clock keeps route-memory TTL tests deterministic while the
  /// production default remains wall-clock time.
  final DateTime Function() clock;

  /// The strict-tier resolver (DoH by default, system when DoH is off).
  /// Exposed for the probe page; production requests use [runLadder].
  SecureResolver get resolver => _resolver;

  /// Per-host route memory: a host that reached a success through a
  /// compatibility tier is remembered so subsequent requests skip the cold
  /// route discovery path. Bounded, TTL'd, and cleared with the same events
  /// that close route pools (mode/revision changes).
  final Map<String, _HostRouteMemory> _routeMemory = {};

  /// A stale persisted address must not make every request pay the fast-tier
  /// timeout before reaching a strict route. The cooldown is process-local;
  /// the persisted address remains available for a later network change.
  final Map<String, DateTime> _fastRouteCooldownUntil = {};

  /// A successful strict route is also remembered for its destination group.
  /// The value changes candidate order only; target addresses remain per-host.
  final Map<_RouteGroup, _RouteGroupMemory> _groupMemory = {};
  static const int _maxRouteMemoryEntries = 32;

  NetworkMode _mode;
  NetworkRevision _revision;
  bool _disposed = false;
  Future<void>? _warmupFuture;

  NetworkMode get mode => _mode;
  NetworkRevision get revision => _revision;

  bool get _fastCompatibilityEnabled =>
      insecureNoSniEnabled && fastRouteStore != null;

  /// Loads the persisted PixEz-compatible addresses and eagerly creates the
  /// corresponding pooled clients. This work is intentionally asynchronous so
  /// the first screen is not held up by preference I/O.
  Future<void> warmUp() {
    if (_disposed) return Future<void>.value();
    return _warmupFuture ??= _warmUp();
  }

  Future<void> _warmUp() async {
    // The warm-up pre-builds native clients; it must wait for rhttp just
    // like business requests do.
    final rhttpReady = RhttpGate.ready;
    if (rhttpReady != null) await rhttpReady;
    final store = fastRouteStore;
    if (!_fastCompatibilityEnabled ||
        store == null ||
        _mode == NetworkMode.directOnly) {
      return;
    }
    final targets = <({PixivDestinationPurpose purpose, String host})>[
      (
        purpose: PixivDestinationPurpose.appApi,
        host: PixivClientIdentity.appApiBase.host,
      ),
      (
        purpose: PixivDestinationPurpose.oauth,
        host: PixivClientIdentity.oauthHost,
      ),
      (
        purpose: PixivDestinationPurpose.pixivWeb,
        host: PixivClientIdentity.webHost,
      ),
      for (final imageHost in PixivClientIdentity.downloadHosts)
        (purpose: PixivDestinationPurpose.image, host: imageHost),
    ];
    for (final target in targets) {
      if (_disposed) return;
      final address = await store.addressFor(target.host);
      if (address == null) continue;
      clientFor(
        target.purpose,
        NetworkRoute.insecureNoSni(
          _revision,
          address,
          dnsSource: DnsSource.doh,
          ttl: _kRouteMemoryTtl,
        ),
        target.host,
      );
      // Match PixEz's startup Hoster refresh: keep the bundled/persisted
      // address available immediately, then update it without delaying the
      // first screen or first business request.
      unawaited(
        store.refresh(target.host, resolver: _resolver, revision: _revision),
      );
    }
  }

  /// Whether [host] is currently remembered as non-direct (strict tier).
  /// Exposed for tests; production callers go through [runLadder].
  @visibleForTesting
  bool hasStrictRouteMemory(String host, {DateTime? now}) =>
      (_routeMemory[host]?.isUsable(
            now ?? clock(),
            _revision.networkIdentity,
          ) ??
          false) &&
      _routeMemory[host]!.kind != NetworkRouteKind.direct;

  /// The remembered route kind for [host], or null when absent/stale.
  @visibleForTesting
  NetworkRouteKind? rememberedRouteKind(String host, {DateTime? now}) {
    final memory = _routeMemory[host];
    if (memory == null ||
        !memory.isUsable(now ?? clock(), _revision.networkIdentity)) {
      return null;
    }
    return memory.kind;
  }

  @visibleForTesting
  NetworkRouteKind? rememberedGroupRouteKind(
    PixivDestinationPurpose purpose, {
    DateTime? now,
  }) {
    final group = _routeGroupFor(purpose);
    final memory = _groupMemory[group];
    if (memory == null) return null;
    if (!memory.isUsable(now ?? clock(), _revision.networkIdentity)) {
      _groupMemory.remove(group);
      return null;
    }
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

  /// The single route ladder shared by the API, OAuth, image and download
  /// exits.
  ///
  /// PixEz-style attempt-first: the business request itself is the route
  /// attempt, so no credential-free probe round trip is paid before data. If
  /// the attempt fails with a transport-level error that proves the request
  /// was never delivered, the ladder walks the remaining unused kinds (ECH
  /// first on a cold start; `insecureNoSni` always last) and sends each
  /// unused kind at most once.
  /// [canReplay] selects the retry set: idempotent GET/HEAD/downloads also
  /// retry on timeout (a repeat is safe), while POST-family and the token
  /// exchange retry only on delivery-proven failures (DNS, connect, reset,
  /// TLS handshake), so a request that may have reached the server (HTTP
  /// response, timeout after send) is never repeated.
  Future<T> runLadder<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required bool canReplay,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
  }) async {
    _checkUsable();
    // First request after a cold start waits for the Rust transport; this
    // keeps `main` free to render the boot before rhttp finishes loading.
    final rhttpReady = RhttpGate.ready;
    if (rhttpReady != null) await rhttpReady;
    return _runAttemptLadder<T>(
      destination: destination,
      cancelSignal: cancelSignal,
      canReplay: canReplay,
      attempt: attempt,
    );
  }

  /// Sends the business request on the selected route and, on a retryable
  /// transport failure, walks the remaining unused kinds. Each tier is
  /// attempted at most once; a delivered outcome (HTTP response, timeout
  /// after send, auth/parse error) never moves on, so a non-idempotent
  /// request can only be repeated when every earlier failure proved the
  /// request never reached the server.
  Future<T> _runAttemptLadder<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required bool canReplay,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
  }) async {
    final host = destination.canonicalHost;
    final attemptedKeys = <String>{};
    final attemptedKinds = <NetworkRouteKind>{};
    var useMemory = true;
    while (true) {
      NetworkRoute route;
      try {
        route = await _selectRoute(
          destination: destination,
          cancelSignal: cancelSignal,
          attemptedKeys: attemptedKeys,
          attemptedKinds: attemptedKinds,
          useMemory: useMemory,
        );
      } on Object catch (error, stackTrace) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      useMemory = false;

      final businessTimer = Stopwatch()..start();
      try {
        final result = await _sendOnRoute(
          destination,
          route,
          attempt,
          cancelSignal,
        );
        _clearFastRouteCooldown(host, route);
        return result;
      } on Object catch (error, stackTrace) {
        policyRecord(destination, route, error, businessTimer.elapsed);
        final eligible = _retryEligible(canReplay, error);
        if (eligible) {
          _invalidateRouteMemory(host, route, purpose: destination.purpose);
          _coolFastRoute(host, route);
        }
        if (_mode == NetworkMode.directOnly ||
            (cancelSignal?.isCancelled ?? false) ||
            !eligible) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        // Advance to the next candidate. [attemptedKinds] already contains
        // this route's kind, so the loop cannot repeat the same tier.
      }
    }
  }

  /// Whether a failed [error] justifies moving on to the next route tier.
  bool _retryEligible(bool canReplay, Object error) {
    final kind = TransportFailureClassifier.classify(error).kind;
    if (canReplay) return _replayEligibleKinds.contains(kind);
    return _unsentEligibleKinds.contains(kind);
  }

  /// Idempotent requests may retry on timeout too — repeating a read is safe.
  static const Set<NetworkFailureKind> _replayEligibleKinds = {
    NetworkFailureKind.dns,
    NetworkFailureKind.connect,
    NetworkFailureKind.timeout,
    NetworkFailureKind.reset,
    NetworkFailureKind.tlsHandshake,
  };

  /// Non-idempotent requests advance only when the failure proves the request
  /// never reached the server, so a delivered request is never repeated.
  static const Set<NetworkFailureKind> _unsentEligibleKinds = {
    NetworkFailureKind.dns,
    NetworkFailureKind.connect,
    NetworkFailureKind.reset,
    NetworkFailureKind.tlsHandshake,
  };

  /// Finds the first candidate route for the operation. The route is *not*
  /// verified here: the business request itself is the attempt (PixEz-style),
  /// so a candidate only needs a usable connect address (fast tier: known
  /// address; direct: no address; ECH: config+front address; DoH tiers: a
  /// resolved address).
  Future<NetworkRoute> _selectRoute({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required Set<String> attemptedKeys,
    required Set<NetworkRouteKind> attemptedKinds,
    bool useMemory = true,
  }) async {
    final host = destination.canonicalHost;
    final now = clock();
    final fastCompatibilityAvailable =
        _fastCompatibilityEnabled && !_isFastRouteCooling(host, now);
    final memory = _routeMemory[host];
    if (memory != null && !memory.isUsable(now, _revision.networkIdentity)) {
      _routeMemory.remove(host);
    }

    // Explicit direct-only mode is a route decision, not a reason to probe
    // and then issue a second direct request.
    if (_mode == NetworkMode.directOnly) {
      final direct = NetworkRoute.direct(_revision);
      attemptedKinds.add(direct.kind);
      attemptedKeys.add(direct.key);
      _rememberRoute(host, direct, purpose: destination.purpose);
      return direct;
    }

    if (useMemory) {
      final remembered = _routeMemory[host];
      if (remembered != null &&
          remembered.isUsable(now, _revision.networkIdentity)) {
        final route = remembered.routeFor(_revision);
        if ((!_isFastRouteCooling(host, now) ||
                route.kind != NetworkRouteKind.insecureNoSni) &&
            !attemptedKinds.contains(route.kind) &&
            attemptedKeys.add(route.key)) {
          attemptedKinds.add(route.kind);
          return route;
        }
      }
    }

    Object? lastError;
    StackTrace? lastStack;
    ResolvedHost? pendingResolved;
    Future<ResolvedHost> resolveOnce() async => pendingResolved ??=
        await resolve(destination, cancelSignal: cancelSignal);

    final preferredKind = rememberedGroupRouteKind(
      destination.purpose,
      now: now,
    );
    final usablePreferredKind =
        preferredKind == NetworkRouteKind.insecureNoSni &&
            !fastCompatibilityAvailable
        ? null
        : preferredKind;
    final fallbackTiers = _fallbackTiersFor(destination.purpose);
    // Verified-fast-first ordering, driven by real-device probe data:
    // Cloudflare hosts (API/OAuth) reach the ECH tier inside the wall while
    // plain SNI is RST; image hosts reach the empty-SNI tier on their origin
    // addresses. The PixEz bootstrap (insecureNoSni) stays as the very last
    // fallback: if it happens to work on this network it is remembered and
    // promoted by route/group memory after one success, but an unverified
    // address can never again cost the first N requests of a screen.
    final hasInsecureFallback = fallbackTiers.contains(
      NetworkRouteKind.insecureNoSni,
    );
    final kinds = <NetworkRouteKind>[
      ?usablePreferredKind,
      ...fallbackTiers.where((kind) => kind != NetworkRouteKind.insecureNoSni),
      NetworkRouteKind.direct,
      if (hasInsecureFallback && !_isFastRouteCooling(host, now))
        NetworkRouteKind.insecureNoSni,
    ];
    for (final kind in kinds) {
      if (attemptedKinds.contains(kind)) continue;
      NetworkRoute? route;
      try {
        route = kind == NetworkRouteKind.direct
            ? NetworkRoute.direct(_revision)
            : await _routeForTier(
                kind,
                destination,
                resolveHost: resolveOnce,
                cancelSignal: cancelSignal,
              );
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        if (_isCancellation(error, cancelSignal)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (usablePreferredKind == kind) {
          _invalidateGroupPreference(destination.purpose, kind);
        }
        continue;
      }
      if (route == null) {
        if (usablePreferredKind == kind) {
          _invalidateGroupPreference(destination.purpose, kind);
        }
        continue;
      }
      if (!attemptedKeys.add(route.key)) {
        attemptedKinds.add(kind);
        continue;
      }
      attemptedKinds.add(kind);

      final timer = Stopwatch()..start();
      try {
        if (cancelSignal?.isCancelled ?? false) {
          throw const NetworkFailureException(NetworkFailureKind.cancelled);
        }
        // PixEz-style: the candidate is not pre-verified. The business
        // request itself is the attempt; a failure falls through to the
        // re-selection in the caller. Only cancellations abort here.
        _rememberRoute(host, route, purpose: destination.purpose);
        return route;
      } on Object catch (error, stackTrace) {
        policyRecord(destination, route, error, timer.elapsed);
        lastError = error;
        lastStack = stackTrace;
        if (_isCancellation(error, cancelSignal) ||
            !TransportFailureClassifier.isFallbackEligible(error)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        _invalidateRouteMemory(host, route, purpose: destination.purpose);
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    throw const NetworkFailureException(NetworkFailureKind.connect);
  }

  Future<T> _sendOnRoute<T>(
    PixivDestination destination,
    NetworkRoute route,
    FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    NetworkCancelSignal? cancelSignal,
  ) async {
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final result = await attempt(route, destination.uri);
    // Refresh (rather than delete) a remembered route on every successful
    // business request.  A successful direct route is the one case that
    // intentionally replaces an older strict preference.
    _rememberRoute(
      destination.canonicalHost,
      route,
      purpose: destination.purpose,
    );
    if (route.kind == NetworkRouteKind.insecureNoSni &&
        fastRouteStore != null) {
      unawaited(_refreshFastRoute(destination.canonicalHost, route.address!));
    }
    return result;
  }

  Future<void> _refreshFastRoute(String host, InternetAddress address) async {
    final store = fastRouteStore;
    if (store == null) return;
    try {
      await store.remember(host, address);
      await store.refresh(host, resolver: _resolver, revision: _revision);
    } on Object {
      // Fast-route persistence is an acceleration layer; the active request
      // has already completed and must not be changed by a cache write error.
    }
  }

  void _rememberRoute(
    String host,
    NetworkRoute route, {
    required PixivDestinationPurpose purpose,
  }) {
    final address = route.address;
    if (route.kind != NetworkRouteKind.direct && address == null) {
      // A strict route without a connect address is not usable and must never
      // become a remembered preference.
      return;
    }
    final now = clock();
    final existing = _routeMemory[host];
    final keepEchCreatedAt =
        route.kind == NetworkRouteKind.ech &&
        existing?.kind == NetworkRouteKind.ech &&
        existing?.routeFor(_revision).key == route.key;
    _routeMemory[host] = _HostRouteMemory(
      address,
      kind: route.kind,
      dnsSource: route.dnsSource,
      ttl: route.ttl ?? _kRouteMemoryTtl,
      createdAt: keepEchCreatedAt ? existing!.createdAt : now,
      networkIdentity: _revision.networkIdentity,
      echConfig: route.echConfig == null
          ? null
          : List<int>.unmodifiable(route.echConfig!),
    );
    final group = _routeGroupFor(purpose);
    if (route.kind == NetworkRouteKind.direct) {
      _groupMemory.remove(group);
    } else if (_isGroupPreferenceKind(route.kind)) {
      final current = _groupMemory[group];
      final keepEchGroupCreatedAt =
          route.kind == NetworkRouteKind.ech &&
          current?.kind == NetworkRouteKind.ech &&
          current?.networkIdentity == _revision.networkIdentity;
      _groupMemory[group] = _RouteGroupMemory(
        kind: route.kind,
        ttl: route.ttl ?? _kRouteMemoryTtl,
        createdAt: keepEchGroupCreatedAt ? current!.createdAt : now,
        networkIdentity: _revision.networkIdentity,
      );
    }
    _trimRouteMemory();
  }

  void _invalidateRouteMemory(
    String host,
    NetworkRoute route, {
    required PixivDestinationPurpose purpose,
  }) {
    final memory = _routeMemory[host];
    if (memory != null &&
        memory.kind == route.kind &&
        memory.networkIdentity == _revision.networkIdentity) {
      final remembered = memory.routeFor(_revision);
      if (remembered.key == route.key) {
        _routeMemory.remove(host);
      }
    }
    final group = _routeGroupFor(purpose);
    final groupMemory = _groupMemory[group];
    if (groupMemory != null &&
        groupMemory.kind == route.kind &&
        groupMemory.networkIdentity == _revision.networkIdentity) {
      _groupMemory.remove(group);
    }
  }

  static const _kFastRouteCooldown = Duration(seconds: 30);

  bool _isFastRouteCooling(String host, DateTime now) {
    final until = _fastRouteCooldownUntil[host];
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _fastRouteCooldownUntil.remove(host);
    return false;
  }

  void _coolFastRoute(String host, NetworkRoute route) {
    if (route.kind != NetworkRouteKind.insecureNoSni ||
        !_fastCompatibilityEnabled) {
      return;
    }
    _fastRouteCooldownUntil[host] = clock().add(_kFastRouteCooldown);
  }

  void _clearFastRouteCooldown(String host, NetworkRoute route) {
    if (route.kind == NetworkRouteKind.insecureNoSni) {
      _fastRouteCooldownUntil.remove(host);
    }
  }

  bool _isCancellation(Object error, NetworkCancelSignal? signal) =>
      signal?.isCancelled == true ||
      TransportFailureClassifier.classify(error).kind ==
          NetworkFailureKind.cancelled;

  /// Ordered fallback tiers after the group preference, per destination
  /// group. Cloudflare hosts (API/OAuth) reach ECH inside the wall (real
  /// SNI is RST) and ECH gives HTTP/2 multiplexing on one connection; image
  /// hosts answer on the ECH front too (real-device probes return reachable
  /// 403/404), and the plain empty-SNI tier on their origin addresses is the
  /// second choice. The PixEz bootstrap (insecureNoSni) is always last: it
  /// is unverified on a cold network and costs a connect timeout when its
  /// address cannot be reached.
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
        : [
            NetworkRouteKind.ech,
            NetworkRouteKind.noSni,
            NetworkRouteKind.dohRealSni,
          ];
    if (insecureNoSniEnabled) {
      tiers.add(NetworkRouteKind.insecureNoSni);
    }
    return tiers;
  }

  static _RouteGroup _routeGroupFor(PixivDestinationPurpose purpose) =>
      switch (purpose) {
        PixivDestinationPurpose.image => _RouteGroup.image,
        PixivDestinationPurpose.appApi ||
        PixivDestinationPurpose.oauth ||
        PixivDestinationPurpose.accountsWeb ||
        PixivDestinationPurpose.pixivWeb => _RouteGroup.cloudflare,
      };

  bool _isGroupPreferenceKind(NetworkRouteKind kind) => switch (kind) {
    NetworkRouteKind.ech ||
    NetworkRouteKind.dohRealSni ||
    NetworkRouteKind.noSni ||
    NetworkRouteKind.insecureNoSni =>
      kind != NetworkRouteKind.insecureNoSni || _fastCompatibilityEnabled,
    NetworkRouteKind.direct => false,
  };

  void _invalidateGroupPreference(
    PixivDestinationPurpose purpose,
    NetworkRouteKind kind,
  ) {
    final group = _routeGroupFor(purpose);
    if (_groupMemory[group]?.kind == kind) _groupMemory.remove(group);
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
        if (ech == null || ech.echConfig.isEmpty) return null;
        final frontAddress =
            ech.frontAddresses.where(isPublicNetworkAddress).firstOrNull ??
            await _resolveFrontHost(cancelSignal: cancelSignal);
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
        final store = fastRouteStore;
        if (store != null) {
          final fastAddress = await store.addressFor(destination.canonicalHost);
          if (fastAddress == null) return null;
          return NetworkRoute.insecureNoSni(
            _revision,
            fastAddress,
            dnsSource: DnsSource.doh,
            ttl: _kRouteMemoryTtl,
          );
        }
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
    if (resolver is! EchConfigResolver) {
      return null;
    }
    final echResolver = resolver as EchConfigResolver;
    try {
      return await echResolver.lookupEchConfig(
        echFrontHost,
        revision: _revision,
        cancelSignal: cancelSignal,
      );
    } on Object catch (error, stackTrace) {
      if (_isCancellation(error, cancelSignal)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
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
    if (resolver is! EchConfigResolver) return null;
    try {
      final resolved = await _resolver.resolve(
        echFrontHost,
        revision: _revision,
        cancelSignal: cancelSignal,
      );
      if (resolved.host != echFrontHost ||
          resolved.revision.value != _revision.value ||
          resolved.revision.networkIdentity != _revision.networkIdentity) {
        return null;
      }
      return resolved.addresses.where(isPublicNetworkAddress).firstOrNull;
    } on Object catch (error, stackTrace) {
      if (_isCancellation(error, cancelSignal)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
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
    _groupMemory.clear();
    _fastRouteCooldownUntil.clear();
  }

  NetworkRevision advanceNetworkRevision({String? networkIdentity}) {
    _revision = NetworkRevision(
      _revision.value + 1,
      networkIdentity: networkIdentity ?? _revision.networkIdentity,
    );
    _closeClients();
    _routeMemory.clear();
    _groupMemory.clear();
    _fastRouteCooldownUntil.clear();
    return _revision;
  }

  void _trimRouteMemory() {
    if (_routeMemory.length <= _maxRouteMemoryEntries) return;
    final oldest = _routeMemory.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry in oldest.take(
      _routeMemory.length - _maxRouteMemoryEntries,
    )) {
      _routeMemory.remove(entry.key);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _closeClients();
    _groupMemory.clear();
    _fastRouteCooldownUntil.clear();
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
    required this.networkIdentity,
    this.echConfig,
  });

  final InternetAddress? address;
  final NetworkRouteKind kind;
  final DnsSource dnsSource;
  final Duration ttl;
  final DateTime createdAt;
  final String networkIdentity;
  final List<int>? echConfig;

  bool isFresh(DateTime now) =>
      !now.isBefore(createdAt) && now.difference(createdAt) < ttl;

  bool isUsable(DateTime now, String currentNetworkIdentity) =>
      networkIdentity == currentNetworkIdentity && isFresh(now);

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

enum _RouteGroup { cloudflare, image }

class _RouteGroupMemory {
  const _RouteGroupMemory({
    required this.kind,
    required this.ttl,
    required this.createdAt,
    required this.networkIdentity,
  });

  final NetworkRouteKind kind;
  final Duration ttl;
  final DateTime createdAt;
  final String networkIdentity;

  bool isUsable(DateTime now, String currentNetworkIdentity) =>
      networkIdentity == currentNetworkIdentity &&
      !now.isBefore(createdAt) &&
      now.difference(createdAt) < ttl;
}

const _kRouteMemoryTtl = Duration(minutes: 10);

/// A policy-aware `package:http` client. The business request is the route
/// attempt (PixEz-style): selection never pays for a separate probe. A
/// retryable undelivered failure walks the remaining unused kinds (ECH
/// first on a cold start; `insecureNoSni` always last). The request is
/// freshly cloned for each attempt because package:http requests are
/// single-use after finalize().
class PixivPolicyHttpClient extends http.BaseClient {
  PixivPolicyHttpClient({required this.policy, required this.purpose});

  final NetworkAccessPolicy policy;
  final PixivDestinationPurpose purpose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final destination = policy.registry.require(request.url, purpose);
    request.followRedirects = false;
    final replayFactory = _safeReplayFactory(request);
    final cancelSignal = _RequestCancelSignal.from(request);
    return policy.runLadder<http.StreamedResponse>(
      destination: destination,
      cancelSignal: cancelSignal,
      // canReplay carries operation idempotency, not cloneability: GET/HEAD
      // may retry on timeout too, while POST-family retries only when the
      // failure proves the request never reached the server.
      canReplay: request.method == 'GET' || request.method == 'HEAD',
      attempt: (route, url) async {
        // A clone is created for each attempt. package:http requests are
        // single-use after finalize(), so reusing one object would turn the
        // allowed retry into a local "already finalized" failure.
        final outbound = replayFactory?.call() ?? request;
        final response = await policy
            .clientFor(purpose, route, destination.canonicalHost)
            .send(outbound);
        if (response.statusCode >= 300 && response.statusCode < 400) {
          await response.stream.drain<void>();
          throw NetworkRedirectException(response.statusCode);
        }
        return response;
      },
    );
  }

  /// Builds a fresh clone for every attempt, so any request shape —
  /// including POST bodies such as the OAuth token exchange — can be
  /// re-sent on each unused kind the ladder still walks.
  static http.BaseRequest Function()? _safeReplayFactory(
    http.BaseRequest request,
  ) {
    if (request is! http.Request) return null;
    final headers = Map<String, String>.from(request.headers);
    final body = List<int>.from(request.bodyBytes);
    return () {
      final abortTrigger = request is http.AbortableRequest
          ? request.abortTrigger
          : null;
      final clone =
          http.AbortableRequest(
              request.method,
              request.url,
              abortTrigger: abortTrigger,
            )
            ..headers.addAll(headers)
            ..followRedirects = false
            ..maxRedirects = request.maxRedirects
            ..persistentConnection = request.persistentConnection
            ..bodyBytes = body;
      return clone;
    };
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
  Future<void>? _warmupFuture;

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

  /// Eagerly constructs the shared API/OAuth/image clients and their fast
  /// route pools. It is idempotent so callers can safely trigger it from the
  /// app lifecycle and from headless widget startup.
  Future<void> warmUp() {
    return _warmupFuture ??= () async {
      client(PixivDestinationPurpose.appApi);
      client(PixivDestinationPurpose.oauth);
      client(PixivDestinationPurpose.image);
      imageCacheManager;
      await policy.warmUp();
    }();
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
