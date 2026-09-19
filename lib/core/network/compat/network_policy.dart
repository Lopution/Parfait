import 'dart:async';
import 'dart:io';

import '../pixiv_client_identity.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'secure_resolver.dart';
import 'network_contracts.dart';
import 'network_fast_route_store.dart';
import 'route_kind_store.dart';
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
    this.routeKindStore,
    this.echFrontHost = 'cloudflare-ech.com',
    this.insecureNoSniEnabled = false,
    @visibleForTesting Duration? imageHeadersTimeout,
    @visibleForTesting Duration? imageIdleTimeout,
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
       _imageHeadersTimeout =
           imageHeadersTimeout ?? _StreamIdleGuardClient.defaultHeadersTimeout,
       _imageIdleTimeout =
           imageIdleTimeout ?? _StreamIdleGuardClient.defaultIdleTimeout,
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

  /// Persists the winning route *kind* per network identity so the next
  /// cold start on the same network seeds the group preference instead of
  /// paying the discovery walk again.
  final RouteKindStore? routeKindStore;

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
  final Duration _imageHeadersTimeout;
  final Duration _imageIdleTimeout;
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
    unawaited(_seedPersistedGroupKinds());
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
    PixivDestinationPurpose purpose,
    String host, {
    DateTime? now,
  }) {
    final group = _routeGroupFor(purpose, host);
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
      () => purpose == PixivDestinationPurpose.image
          ? _StreamIdleGuardClient(
              _clientFactory(route, canonicalHost, purpose),
              headersTimeout: _imageHeadersTimeout,
              idleTimeout: _imageIdleTimeout,
            )
          : _clientFactory(route, canonicalHost, purpose),
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
    // Re-seed group preferences for the *new* identity — the same store
    // that accelerates a cold restart accelerates a Wi-Fi↔cellular flip.
    unawaited(_seedPersistedGroupKinds());
    return _revision;
  }

  /// Seeds group route-kind preferences persisted for the current network
  /// identity. Groups that already learned a preference this session keep
  /// it — a live success is fresher than any persisted hint.
  Future<void> _seedPersistedGroupKinds() async {
    final store = routeKindStore;
    if (store == null || _disposed) return;
    final kinds = await store.kindsFor(_revision.networkIdentity);
    if (kinds == null || _disposed) return;
    final now = clock();
    for (final entry in kinds.entries) {
      final group = _RouteGroup.values
          .where((g) => g.name == entry.key)
          .firstOrNull;
      if (group == null || _groupMemory.containsKey(group)) continue;
      final kind = NetworkRouteKind.values
          .where((k) => k.name == entry.value)
          .firstOrNull;
      if (kind == null || !_isGroupPreferenceKind(kind)) continue;
      _groupMemory[group] = _RouteGroupMemory(
        kind: kind,
        ttl: _kRouteMemoryTtl,
        createdAt: now,
        networkIdentity: _revision.networkIdentity,
      );
    }
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

/// Adds the two streaming budgets a route's connect timeout cannot express.
/// Image-purpose routes deliberately carry no *total* request timeout (a
/// large download must not abort mid-body — see
/// [RhttpClientFactory.timeoutsFor]), which left two unbounded waits:
/// `send()` (connect+TLS+request+first byte) and each gap between body
/// chunks. A socket that stalls at either point previously hung the
/// request forever; the route ladder never got a chance to advance.
///
/// A headers deadline miss surfaces from `send()` as a `timeout`, so the
/// ladder can advance for idempotent GETs. A body stall surfaces on the
/// stream as a `TimeoutException`: the image cache shows a visible error
/// and the download manager retries through its resume anchor. The
/// abandoned inner request is not aborted (`http.Client` exposes no
/// abort); reqwest reclaims the socket when the future/stream dies.
class _StreamIdleGuardClient extends http.BaseClient {
  _StreamIdleGuardClient(
    this._inner, {
    this.headersTimeout = defaultHeadersTimeout,
    this.idleTimeout = defaultIdleTimeout,
  });

  final http.Client _inner;

  /// Time budget for `send()` to resolve, i.e. until response headers.
  final Duration headersTimeout;

  /// Maximum gap between body chunks before the stream errors out.
  final Duration idleTimeout;

  static const defaultHeadersTimeout = Duration(seconds: 15);
  static const defaultIdleTimeout = Duration(seconds: 15);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request).timeout(headersTimeout);
    return http.StreamedResponse(
      http.ByteStream(_IdleGuardStream(response.stream, idleTimeout)),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// Per-chunk idle deadline for a response body. Implemented as a `Stream`
/// subclass that forwards the source subscription directly — deliberately
/// NOT `Stream.timeout` or a `StreamController` pass-through, because
/// controller-based wrappers never deliver under `testWidgets`' FakeAsync
/// event loop (they would silently stall every image load in widget
/// tests). Forwarding `listen` keeps the source's own delivery path, so
/// data/done flow through one synchronous hop with no extra buffering.
///
/// On an idle gap the listener's error handler gets a `TimeoutException`
/// and the source subscription is cancelled, releasing the socket.
class _IdleGuardStream extends Stream<List<int>> {
  _IdleGuardStream(this._source, this.idle);

  final Stream<List<int>> _source;
  final Duration idle;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    Timer? timer;
    late StreamSubscription<List<int>> sub;
    void emitError(Object error, StackTrace stack) {
      final handler = onError;
      if (handler is void Function(Object, StackTrace)) {
        handler(error, stack);
      } else if (handler is void Function(Object)) {
        handler(error);
      }
    }

    void rearm() {
      timer?.cancel();
      timer = Timer(idle, () {
        emitError(
          TimeoutException('response stream idle', idle),
          StackTrace.current,
        );
        unawaited(sub.cancel());
      });
    }

    sub = _source.listen(
      (event) {
        rearm();
        onData?.call(event);
      },
      onError: (Object error, StackTrace stack) {
        timer?.cancel();
        emitError(error, stack);
      },
      onDone: () {
        timer?.cancel();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    rearm();
    return sub;
  }
}

enum _RouteGroup { cloudflare, image, imageMirror }

/// Groups only ever share route-*kind* preferences, never addresses.
/// Third-party image mirrors form their own group: a `noSni`/`ech`
/// preference learned on pximg must not leak onto a mirror (its default
/// vhost may not carry the mirror name, and certificate mismatches are
/// terminal on strict tiers). Mirror preferences still propagate between
/// mirrors — a wrong guess costs one failed handshake, then the ladder
/// falls through (see `_retryEligible`'s empty-SNI exception).
_RouteGroup _routeGroupFor(PixivDestinationPurpose purpose, String host) =>
    switch (purpose) {
      PixivDestinationPurpose.image =>
        PixivClientIdentity.downloadHosts.contains(host)
            ? _RouteGroup.image
            : _RouteGroup.imageMirror,
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
