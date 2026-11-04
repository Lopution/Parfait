import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../../log.dart';
import '../local_network_address.dart';
import '../pixiv_client_identity.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'image_route_scores.dart';
import 'network_fast_route_store.dart';
import 'secure_resolver.dart';
import 'network_contracts.dart';
import 'route_memory.dart';
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
    this.imageRouteScoreStore,
    this.echFrontHost = 'cloudflare-ech.com',
    this.bootstrapNoSniEnabled = false,
    this.localNetworkBlockedHosts = const {},
    @visibleForTesting Duration? imageHeadersTimeout,
    @visibleForTesting Duration? imageIdleTimeout,
    @visibleForTesting Duration imageHeadersStall = ImageStall.headers,
    @visibleForTesting Duration imageBodyStall = ImageStall.body,
    List<String> dohEndpoints = const [
      // Cloudflare DoH over its well-known anycast IPs (proven bootstrap:
      // `1dot1dot1dot1.cloudflare-dns.com` + static IP map).
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
      // Query the ECH config through Alibaba DNS
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
                   blockedHosts: localNetworkBlockedHosts,
                   hostOverrides: dohHostOverrides ?? _defaultDohHostOverrides,
                   echEndpointUrls: echDoHEndpoints,
                 )),
       diagnostics = diagnostics ?? NetworkDiagnostics(),
       _mode = mode,
       _revision = revision,
       _imageScores = ImageRouteScores(clock: clock),
       _imageHeadersTimeout =
           imageHeadersTimeout ?? _StreamIdleGuardClient.defaultHeadersTimeout,
       _imageIdleTimeout =
           imageIdleTimeout ?? _StreamIdleGuardClient.defaultIdleTimeout,
       _imageHeadersStall = imageHeadersStall,
       _imageBodyStall = imageBodyStall,
       _clientFactory = clientFactory ?? RhttpClientFactory.create {
    unawaited(_seedImageRouteScores());
  }

  /// ECH front host used to fetch the ECH config (Cloudflare serves the
  /// ECH config for pixiv domains via this host; configurable in settings).
  final String echFrontHost;

  /// Whether pixiv's origin addresses are a route candidate of its image
  /// hosts (as a `bootstrapNoSni` route). Production enables it together
  /// with [fastRouteStore]; tests and standalone callers opt in, so their
  /// image requests never reach the built-in addresses.
  final bool bootstrapNoSniEnabled;

  /// User-configured hosts on the local network the app may not reach
  /// (see `LocalNetworkBlockedHosts`): requests to them fail at once with
  /// [LocalNetworkBlocked] instead of hanging until the connect times out.
  final Set<String> localNetworkBlockedHosts;

  /// The origin address each pixiv image host last loaded from, where its
  /// origin candidate starts; an origin success teaches it.
  final FastRouteMemory? fastRouteStore;

  /// Persists the winning route *kind* per network identity so the next
  /// cold start on the same network seeds the group preference instead of
  /// paying the discovery walk again.
  final RouteKindMemory? routeKindStore;

  /// What pixiv's image route candidates scored per network identity: it
  /// seeds each new board and is told every sample.
  final ImageRouteScoreMemory? imageRouteScoreStore;

  /// Cloudflare DoH endpoints' anycast IPs (the
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

  /// Invoked when an image-purpose request to a non-canonical (mirror)
  /// host exhausted every ladder tier — the auto image-source selection
  /// uses it to drop a dead winner and re-race. The original error still
  /// propagates to the request caller.
  void Function(String host)? onImageHostExhausted;

  /// Invoked after [advanceNetworkRevision] — the image worker isolate
  /// follows the main isolate's network identity through it.
  void Function(NetworkRevision revision)? onRevisionAdvanced;

  /// The strict-tier resolver (DoH by default, system when DoH is off).
  /// Exposed for the probe page; production requests use [runLadder].
  SecureResolver get resolver => _resolver;

  /// Per-host route memory: a host that reached a success through a
  /// compatibility tier is remembered so subsequent requests skip the cold
  /// route discovery path. Bounded, TTL'd, and cleared with the same events
  /// that close route pools (mode/revision changes).
  final Map<String, _HostRouteMemory> _routeMemory = {};

  /// How pixiv's image route candidates have been loading on the current
  /// network; they keep no other memory. A new network starts a new board.
  ImageRouteScores _imageScores;

  /// Each pixiv image host's origin addresses and the one in use.
  final Map<String, _OriginBook> _originBooks = {};

  /// A successful strict route is also remembered for its destination group.
  /// The value changes candidate order only; target addresses remain per-host.
  final Map<_RouteGroup, _RouteGroupMemory> _groupMemory = {};
  static const int _maxRouteMemoryEntries = 32;

  NetworkMode _mode;
  NetworkRevision _revision;
  final Duration _imageHeadersTimeout;
  final Duration _imageIdleTimeout;
  final Duration _imageHeadersStall;
  final Duration _imageBodyStall;
  bool _disposed = false;
  Future<void>? _warmupFuture;

  NetworkMode get mode => _mode;
  NetworkRevision get revision => _revision;

  /// Loads the persisted origin addresses and eagerly creates their pooled
  /// clients. This work is intentionally asynchronous so the first screen
  /// is not held up by preference I/O.
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
    if (!bootstrapNoSniEnabled ||
        fastRouteStore == null ||
        _mode == NetworkMode.directOnly) {
      return;
    }
    // The origin candidate serves pixiv's image hosts only.
    for (final host in PixivClientIdentity.downloadHosts) {
      final route = await _originRoute(host);
      if (_disposed) return;
      clientFor(PixivDestinationPurpose.image, route, host);
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

  /// Currently-usable remembered route kinds per host — the network
  /// settings page renders this as the effective-route display.
  Map<String, NetworkRouteKind> effectiveRouteSnapshot({DateTime? now}) {
    final at = now ?? clock();
    final snapshot = <String, NetworkRouteKind>{};
    for (final entry in _routeMemory.entries) {
      if (entry.value.isUsable(at, _revision.networkIdentity)) {
        snapshot[entry.key] = entry.value.kind;
      }
    }
    return snapshot;
  }

  /// The pixiv image route candidates the current network has samples
  /// of, cheapest first, for the network settings page. The Cloudflare
  /// fronts are numbered in the order of their addresses.
  List<ImageRouteStanding> imageRouteStandings() {
    final scores = {
      for (final MapEntry(:key, :value) in _imageScores.snapshot().entries)
        if (value.weight > 0) key: value,
    };
    final fronts = scores.keys.where((key) => key != _originCandidate).toList()
      ..sort();
    return [
      for (final MapEntry(key: candidate, value: score) in scores.entries)
        ImageRouteStanding(
          cloudflare: candidate == _originCandidate
              ? null
              : fronts.indexOf(candidate) + 1,
          cost: score.cost,
          failureShare: score.failureShare,
          inUse: candidate == _imageScores.chosen,
        ),
    ]..sort((a, b) => a.cost.compareTo(b.cost));
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
              headersStall: _imageHeadersStall,
              bodyStall: _imageBodyStall,
              observer:
                  _routeGroupFor(purpose, canonicalHost) == _RouteGroup.image
                  ? _CandidateObserver(this, canonicalHost, route)
                  : null,
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

  /// [route]'s candidate while its network is current: what a closed
  /// network's transfers show is not this network's.
  String? _currentCandidate(NetworkRoute route) {
    if (_disposed ||
        route.revision.value != _revision.value ||
        route.revision.networkIdentity != _revision.networkIdentity) {
      return null;
    }
    return _imageCandidateKey(route.kind, route.address);
  }

  void _recordImageSample(
    NetworkRoute route,
    ImageRouteSample Function(String candidate, DateTime at) sample,
  ) {
    final candidate = _currentCandidate(route);
    if (candidate != null) {
      recordImageRouteSample(
        route.revision.networkIdentity,
        sample(candidate, clock()),
      );
    }
  }

  /// [sample] was taken on [networkIdentity], here or in the image worker:
  /// the board learns it while that network is current, the store always.
  void recordImageRouteSample(String networkIdentity, ImageRouteSample sample) {
    if (!_disposed && networkIdentity == _revision.networkIdentity) {
      _imageScores.record(sample);
    }
    imageRouteScoreStore?.record(networkIdentity, sample);
  }

  /// [candidate] answered a `Range` request on [networkIdentity], here or
  /// in the image worker; see [recordImageRouteSample].
  void noteImageRouteRanges(
    String networkIdentity,
    String candidate, {
    required bool served,
  }) {
    if (!_disposed && networkIdentity == _revision.networkIdentity) {
      _imageScores.noteRanges(candidate, served: served);
    }
    imageRouteScoreStore?.noteRanges(
      networkIdentity,
      candidate,
      served: served,
    );
  }

  /// Seeds the current board with what its network taught before. Each
  /// board is seeded once, when it starts; samples it takes meanwhile add
  /// up with the seed.
  Future<void> _seedImageRouteScores() async {
    final store = imageRouteScoreStore;
    if (store == null) return;
    final board = _imageScores;
    final scores = await store.scoresFor(_revision.networkIdentity);
    if (!_disposed && identical(board, _imageScores)) board.seed(scores);
  }

  /// A failure before the body, a stall in it or a server error: the
  /// candidate pays for it, and an origin address gives way to the next.
  void _imageRouteFailed(String host, NetworkRoute route) {
    _recordImageSample(
      route,
      (candidate, at) => ImageRouteSample.failure(candidate, at: at),
    );
    final address = route.address;
    if (route.kind == NetworkRouteKind.bootstrapNoSni && address != null) {
      _originBooks[host]?.failed(address);
    }
  }

  /// Changes mode and invalidates all route pools and route memory. This is
  /// deliberately synchronous because `http.Client.close` is synchronous; no
  /// caller can issue another request through the old pool after this method
  /// returns.
  void setMode(NetworkMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _forgetRoutes();
  }

  NetworkRevision advanceNetworkRevision({String? networkIdentity}) {
    final identity = networkIdentity ?? _revision.networkIdentity;
    final newNetwork = identity != _revision.networkIdentity;
    if (newNetwork) _imageScores = ImageRouteScores(clock: clock);
    _revision = NetworkRevision(_revision.value + 1, networkIdentity: identity);
    if (newNetwork) unawaited(_seedImageRouteScores());
    _forgetRoutes();
    // Re-seed group preferences for the *new* identity — the same store
    // that accelerates a cold restart accelerates a Wi-Fi↔cellular flip.
    unawaited(_seedPersistedGroupKinds());
    onRevisionAdvanced?.call(_revision);
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
      // Older versions persisted pixiv image preferences; their scores
      // replace them.
      if (kind == null || !_isGroupPreference(group, kind)) continue;
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
    _forgetRoutes();
    await _resolver.dispose();
  }

  /// Closes the route pools and drops what won on the current network.
  /// Image route scores are the network's own and go only with it.
  void _forgetRoutes() {
    _closeClients();
    _routeMemory.clear();
    _groupMemory.clear();
    _originBooks.clear();
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

/// A pixiv image host's origin addresses and the one in use, which moves
/// on after a failure there.
class _OriginBook {
  _OriginBook(this.addresses);

  final List<InternetAddress> addresses;
  var _index = 0;

  InternetAddress get current => addresses[_index];

  /// Requests that failed together on one address move the book once.
  void failed(InternetAddress address) {
    if (address.address == current.address) {
      _index = (_index + 1) % addresses.length;
    }
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
/// and the download manager retries through its resume anchor. Either
/// way, and whenever a reader gives the body up, the request's abort
/// trigger fires: rhttp keeps the transfer and its socket otherwise.
///
/// A request given up, by its reader or by its own abort trigger, counts
/// against its route candidate when it had stalled ([ImageStall]): no
/// headers for [headersStall], or no body bytes for [bodyStall].
class _StreamIdleGuardClient extends http.BaseClient {
  _StreamIdleGuardClient(
    this._inner, {
    this.headersTimeout = defaultHeadersTimeout,
    this.idleTimeout = defaultIdleTimeout,
    this.headersStall = ImageStall.headers,
    this.bodyStall = ImageStall.body,
    _CandidateObserver? observer,
  }) : _observer = observer;

  final http.Client _inner;

  /// Hears how bodies end on a pixiv image route candidate.
  final _CandidateObserver? _observer;

  /// Time budget for `send()` to resolve, i.e. until response headers.
  final Duration headersTimeout;

  /// Maximum gap between body chunks before the stream errors out.
  final Duration idleTimeout;

  final Duration headersStall;
  final Duration bodyStall;

  static const defaultHeadersTimeout = Duration(seconds: 15);
  static const defaultIdleTimeout = Duration(seconds: 15);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // rhttp's transfer, and its socket, outlive a dropped body or a
    // timed-out send until the server sends again; aborting the request
    // ends them, so a lane freed by a timeout never leaves one behind.
    final abandoned = Completer<void>();
    void abandon() {
      if (!abandoned.isCompleted) abandoned.complete();
    }

    final trigger = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    var givenUp = false;
    unawaited(trigger?.then((_) => givenUp = true, onError: (_) {}));
    final sent = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _inner
          .send(_abortable(request, abandoned.future))
          .timeout(headersTimeout);
    } on TimeoutException {
      abandon();
      rethrow;
    } on Object {
      if (givenUp && sent.elapsed >= headersStall) _observer?.failed();
      rethrow;
    }
    return http.StreamedResponse(
      http.ByteStream(
        _IdleGuardStream(
          response.stream,
          idleTimeout,
          stall: bodyStall,
          givenUp: trigger,
          onAbandon: abandon,
          onEnd: _bodyEnd(request, response, sent),
        ),
      ),
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

  /// Tells the observer what [response] shows of its route: a `Range`
  /// answered or ignored, a server error, or (through the returned
  /// callback) how a 2xx body ends. Other answers say nothing of the
  /// route.
  void Function(_BodyEnd end, int bytes)? _bodyEnd(
    http.BaseRequest request,
    http.StreamedResponse response,
    Stopwatch sent,
  ) {
    final observer = _observer;
    if (observer == null) return null;
    final status = response.statusCode;
    if (request.headers.containsKey('range') &&
        (status == 200 || status == 206)) {
      observer.answeredRange(served: status == 206);
    }
    if (status >= 500) {
      observer.failed();
      return null;
    }
    if (status < 200 || status >= 300) {
      observer.abandoned();
      return null;
    }
    final headers = sent.elapsed;
    return (end, bytes) => switch (end) {
      _BodyEnd.done => observer.loaded(
        headers: headers,
        total: sent.elapsed,
        bytes: bytes,
      ),
      _BodyEnd.failed => observer.failed(),
      _BodyEnd.abandoned => observer.abandoned(),
    };
  }

  /// [request] whose abort trigger also fires on [abandoned]. Image and
  /// download exits send plain [http.Request]s; any other shape goes out
  /// as it is.
  static http.BaseRequest _abortable(
    http.BaseRequest request,
    Future<void> abandoned,
  ) {
    if (request is! http.Request) return request;
    final trigger = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    return http.AbortableRequest(
        request.method,
        request.url,
        abortTrigger: trigger == null
            ? abandoned
            : Future.any([trigger, abandoned]),
      )
      ..headers.addAll(request.headers)
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..bodyBytes = request.bodyBytes;
  }
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
/// and the source subscription is cancelled, releasing the socket. A body
/// its reader cancels, or whose request is aborted ([givenUp]), ends
/// failed when it had brought nothing for [stall], else abandoned.
class _IdleGuardStream extends Stream<List<int>> {
  _IdleGuardStream(
    this._source,
    this.idle, {
    required this.stall,
    required this.givenUp,
    required this.onAbandon,
    this.onEnd,
  });

  final Stream<List<int>> _source;
  final Duration idle;
  final Duration stall;
  final Future<void>? givenUp;

  /// Aborts the request once its body is given up.
  final void Function() onAbandon;

  /// Told once how the body ended, and how many bytes it brought.
  final void Function(_BodyEnd end, int bytes)? onEnd;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _IdleGuardSubscription(
    _source,
    idle,
    stall: stall,
    givenUp: givenUp,
    onAbandon: onAbandon,
    onEnd: onEnd,
    onData: onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError ?? false,
  );
}

/// Holds the handlers itself, so the ones set after `listen` — `asFuture`
/// (behind `drain`) or `onError` — still see the idle timeout. Forwarding them to the source subscription left `drain()` on a
/// stalled body waiting forever.
class _IdleGuardSubscription implements StreamSubscription<List<int>> {
  _IdleGuardSubscription(
    Stream<List<int>> source,
    this._idle, {
    required Duration stall,
    required Future<void>? givenUp,
    required void Function() onAbandon,
    required void Function(_BodyEnd end, int bytes)? onEnd,
    required void Function(List<int> event)? onData,
    required Function? onError,
    required void Function()? onDone,
    required bool cancelOnError,
  }) : _onAbandon = onAbandon,
       _onEnd = onEnd,
       _onData = onData,
       _onError = onError,
       _onDone = onDone,
       _cancelOnError = cancelOnError,
       _stall = stall {
    _source = source.listen(_data, onError: _sourceError, onDone: _done);
    _rearm();
    // Before the abort's own error, which would read as the route's.
    unawaited(givenUp?.then((_) => _end(_givenUp), onError: (_) {}));
  }

  /// The listener's zone: the idle timer runs in the root zone.
  final Zone _zone = Zone.current;
  final Duration _idle;
  final void Function() _onAbandon;
  final void Function(_BodyEnd end, int bytes)? _onEnd;
  final bool _cancelOnError;
  final Duration _stall;

  /// Since the headers or the last chunk.
  final _quiet = Stopwatch()..start();
  var _bytes = 0;
  var _ended = false;
  late final StreamSubscription<List<int>> _source;
  void Function(List<int> event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  Timer? _timer;

  void _data(List<int> event) {
    _rearm();
    _quiet.reset();
    _bytes += event.length;
    _onData?.call(event);
  }

  _BodyEnd get _givenUp =>
      _quiet.elapsed >= _stall ? _BodyEnd.failed : _BodyEnd.abandoned;

  void _end(_BodyEnd end) {
    if (_ended) return;
    _ended = true;
    _onEnd?.call(end, _bytes);
  }

  void _sourceError(Object error, StackTrace stack) {
    _end(_BodyEnd.failed);
    if (_cancelOnError) {
      _timer?.cancel();
      unawaited(_cancelSource());
    } else {
      // The body goes on after the error; so does its idle budget.
      _rearm();
    }
    _error(error, stack);
  }

  /// Like any subscription, an error without a handler is the zone's.
  void _error(Object error, StackTrace stack) {
    final handler = _onError;
    if (handler is void Function(Object, StackTrace)) {
      handler(error, stack);
    } else if (handler is void Function(Object)) {
      handler(error);
    } else {
      _zone.handleUncaughtError(error, stack);
    }
  }

  void _done() {
    _timer?.cancel();
    _end(_BodyEnd.done);
    _onDone?.call();
  }

  void _rearm() {
    _timer?.cancel();
    // The idle budget is wall-clock semantics, so the timer is rooted in
    // the real zone: a fake-zone timer (widget tests) would stay pending
    // for any stream still draining at teardown, and in production there
    // is no fake zone anyway.
    _timer = Zone.root.createTimer(_idle, () {
      _end(_BodyEnd.failed);
      unawaited(_cancelSource());
      _error(
        TimeoutException('response stream idle', _idle),
        StackTrace.current,
      );
    });
  }

  /// Also stops the idle timer: an abandoned body (raced loser drained
  /// late, caller gone) would otherwise leak a pending timer until it fires.
  ///
  /// Completes at once rather than with the source's cancel, which on rhttp
  /// waits for Rust's next event: a `.map` under `await for` hands an error
  /// on only after the cancel it started ends, so the idle timeout reached
  /// the image cache 15–30 s late.
  @override
  Future<void> cancel() {
    _timer?.cancel();
    _end(_givenUp);
    unawaited(_cancelSource());
    return Future<void>.value();
  }

  /// rhttp's body is flutter_rust_bridge's `async*` stream: cancelled while
  /// it waits for Rust, it goes on waiting, and a body error Rust reports
  /// next fails the cancel future instead of reaching any handler. The
  /// listener gave the body up, so that error is dropped; unhandled, it
  /// ended the image worker isolate. The request's abort ends the transfer
  /// on the Rust side.
  Future<void> _cancelSource() {
    _onAbandon();
    return _source.cancel().catchError((Object _) {});
  }

  @override
  void onData(void Function(List<int> event)? handleData) =>
      _onData = handleData;

  @override
  void onError(Function? handleError) => _onError = handleError;

  @override
  void onDone(void Function()? handleDone) => _onDone = handleDone;

  @override
  void pause([Future<void>? resumeSignal]) => _source.pause(resumeSignal);

  @override
  void resume() => _source.resume();

  @override
  bool get isPaused => _source.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final result = Completer<E>();
    _onDone = () => result.complete(futureValue as E);
    _onError = (Object error, StackTrace stack) {
      unawaited(cancel());
      result.completeError(error, stack);
    };
    return result.future;
  }
}

enum _BodyEnd { done, failed, abandoned }

/// Hears how the transfers on one pixiv image route candidate end, for the
/// policy's scores.
class _CandidateObserver {
  _CandidateObserver(this._policy, this._host, this._route);

  final NetworkAccessPolicy _policy;
  final String _host;
  final NetworkRoute _route;

  void loaded({
    required Duration headers,
    required Duration total,
    required int bytes,
  }) => _policy._recordImageSample(
    _route,
    (candidate, at) => ImageRouteSample.load(
      candidate,
      headers: headers,
      total: total,
      bytes: bytes,
      at: at,
    ),
  );

  void failed() => _policy._imageRouteFailed(_host, _route);

  /// Given up while healthy: no sample, but an exploration is over.
  void abandoned() {
    final candidate = _policy._currentCandidate(_route);
    if (candidate != null) _policy._imageScores.release(candidate);
  }

  void answeredRange({required bool served}) {
    final candidate = _policy._currentCandidate(_route);
    if (candidate != null) {
      _policy.noteImageRouteRanges(
        _route.revision.networkIdentity,
        candidate,
        served: served,
      );
    }
  }
}

/// The candidate a pixiv image route is: [_originCandidate], or
/// `ech:<front>`.
String? _imageCandidateKey(NetworkRouteKind kind, InternetAddress? address) =>
    switch (kind) {
      NetworkRouteKind.bootstrapNoSni => _originCandidate,
      NetworkRouteKind.ech when address != null => 'ech:${address.address}',
      _ => null,
    };

const _originCandidate = 'origin';

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
