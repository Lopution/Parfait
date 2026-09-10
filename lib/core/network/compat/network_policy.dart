import 'dart:async';
import 'dart:io';

import '../pixiv_client_identity.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'secure_resolver.dart';
import 'network_contracts.dart';
import 'network_fast_route_store.dart';
import 'rhttp_client_factory.dart';
import '../rhttp_gate.dart';

part 'network_policy_ladder.dart';

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

_RouteGroup _routeGroupFor(PixivDestinationPurpose purpose) =>
    switch (purpose) {
      PixivDestinationPurpose.image => _RouteGroup.image,
      PixivDestinationPurpose.appApi ||
      PixivDestinationPurpose.oauth ||
      PixivDestinationPurpose.accountsWeb ||
      PixivDestinationPurpose.pixivWeb => _RouteGroup.cloudflare,
    };

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
