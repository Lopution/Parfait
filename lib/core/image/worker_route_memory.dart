import 'dart:io';

import '../network/compat/image_route_discovery.dart';
import '../network/compat/image_route_scores.dart';
import '../network/compat/network_fast_route_store.dart';
import '../network/compat/proven_origins.dart';
import '../network/compat/route_memory.dart';
import '../network/compat/secure_resolver.dart';

/// In-memory route memory for the image worker isolate.
///
/// SharedPreferences is platform-channel backed and therefore unreachable
/// off the main isolate, so the worker keeps learned routes in memory and
/// reports every write through [onFastRouteLearned]/[onRouteKindLearned] —
/// the client forwards them to the main isolate, which persists them into
/// the real stores. Semantics (bootstrap fallback, host allowlist,
/// public-address gate) mirror `PixivFastRouteStore` so the worker's ladder
/// makes the same decisions the main isolate's would.
///
/// `FastRouteMemory` and `RouteKindMemory` cannot live on one class — both
/// declare `remember` with different signatures — so the worker carries a
/// pair sharing one [WorkerRouteMemoryState].
class WorkerFastRouteMemory implements FastRouteMemory {
  WorkerFastRouteMemory(
    this._state, {
    this.onFastRouteLearned,
    this.onOriginsProven,
  });

  final WorkerRouteMemoryState _state;
  final void Function(String host, String address)? onFastRouteLearned;
  final void Function(ProvenOrigins origins)? onOriginsProven;

  @override
  Future<ProvenOrigins?> provenOrigins() async => _state.origins;

  @override
  void proveOrigins(ProvenOrigins origins) {
    _state
      ..origins = origins
      ..originsProvenHere = true;
    onOriginsProven?.call(origins);
  }

  @override
  Future<InternetAddress?> addressFor(String host) async {
    return _state.fastRoutes[host] ?? PixivFastRouteStore.bootstrap[host];
  }

  @override
  Future<void> remember(String host, InternetAddress address) async {
    if (!_allowlisted(host, address)) return;
    if (_state.fastRoutes[host]?.address == address.address) return;
    _state.fastRoutes[host] = address;
    onFastRouteLearned?.call(host, address.address);
  }
}

/// The per-network-identity route-kind hints, in memory like
/// [WorkerFastRouteMemory]. The worker only ever serves the identity it
/// was initialized with, so learned kinds are one flat map re-seeded on a
/// config push.
class WorkerRouteKindMemory implements RouteKindMemory {
  WorkerRouteKindMemory(this._state, {this.onRouteKindLearned});

  final WorkerRouteMemoryState _state;
  final void Function(String identity, String group, String kind)?
  onRouteKindLearned;

  @override
  Future<Map<String, String>?> kindsFor(String networkIdentity) async {
    return _state.routeKinds.isEmpty ? null : _state.routeKinds;
  }

  @override
  Future<void> remember(
    String networkIdentity,
    String group,
    String kind,
  ) async {
    _state.routeKinds[group] = kind;
    onRouteKindLearned?.call(networkIdentity, group, kind);
  }
}

/// What pixiv's image routes scored on the worker's network, as the main
/// isolate's store had it when the config came. Samples and range marks
/// go back through [onSample] and [onRanges], front discovery through
/// [onDiscovery]: the main isolate's policy learns them and its store
/// persists them.
class WorkerImageRouteScoreMemory implements ImageRouteScoreMemory {
  WorkerImageRouteScoreMemory({this.onSample, this.onRanges, this.onDiscovery});

  final void Function(String identity, ImageRouteSample sample)? onSample;
  final void Function(String identity, String candidate, bool served)? onRanges;
  final void Function(String identity, ImageRouteDiscovery discovery)?
  onDiscovery;

  var _identity = '';
  Map<String, ImageRouteScore> _scores = const {};

  /// By identity: the configs', and what this worker came to since, which
  /// is newer than a config sent before the main isolate heard of it.
  final _discoveries = <String, ImageRouteDiscovery>{};
  final _discoveredHere = <String>{};

  /// Takes a config's scores and discovery, which are [networkIdentity]'s.
  void reseed(
    String networkIdentity,
    Map<String, ImageRouteScore> scores,
    ImageRouteDiscovery? discovery,
  ) {
    _identity = networkIdentity;
    _scores = scores;
    if (discovery != null && !_discoveredHere.contains(networkIdentity)) {
      _discoveries[networkIdentity] = discovery;
    }
  }

  @override
  Future<ImageRouteDiscovery?> discoveryFor(String networkIdentity) async =>
      _discoveries[networkIdentity];

  @override
  void discovered(String networkIdentity, ImageRouteDiscovery discovery) {
    _discoveries[networkIdentity] = discovery;
    _discoveredHere.add(networkIdentity);
    onDiscovery?.call(networkIdentity, discovery);
  }

  @override
  Future<Map<String, ImageRouteScore>> scoresFor(
    String networkIdentity,
  ) async => networkIdentity == _identity ? _scores : const {};

  @override
  void record(String networkIdentity, ImageRouteSample sample) =>
      onSample?.call(networkIdentity, sample);

  @override
  void noteRanges(
    String networkIdentity,
    String candidate, {
    required bool served,
  }) => onRanges?.call(networkIdentity, candidate, served);
}

/// Shared state behind the two worker memory adapters.
class WorkerRouteMemoryState {
  WorkerRouteMemoryState({
    Map<String, String> learnedFastRoutes = const {},
    Map<String, String> routeKinds = const {},
    this.origins,
  }) : fastRoutes = _parse(learnedFastRoutes),
       routeKinds = Map.of(routeKinds);

  final Map<String, InternetAddress> fastRoutes;
  final Map<String, String> routeKinds;

  /// The config's, until this worker refreshes them: its own are newer
  /// than a config sent before the main isolate heard of them.
  ProvenOrigins? origins;
  var originsProvenHere = false;

  /// Takes a config's proven origins unless this worker has its own.
  void reseedOrigins(ProvenOrigins? next) {
    if (!originsProvenHere) origins = next;
  }

  /// Replaces the seeded memory on a config push — a new network identity
  /// invalidates what the old one learned, matching `advanceNetworkRevision`.
  void reseed({
    Map<String, String> learnedFastRoutes = const {},
    Map<String, String> routeKinds = const {},
  }) {
    fastRoutes
      ..clear()
      ..addAll(_parse(learnedFastRoutes));
    this.routeKinds
      ..clear()
      ..addAll(routeKinds);
  }

  static Map<String, InternetAddress> _parse(Map<String, String> source) {
    final result = <String, InternetAddress>{};
    for (final entry in source.entries) {
      final address = InternetAddress.tryParse(entry.value);
      if (address != null && _allowlisted(entry.key, address)) {
        result[entry.key] = address;
      }
    }
    return result;
  }
}

bool _allowlisted(String host, InternetAddress address) =>
    PixivFastRouteStore.bootstrap.containsKey(host) &&
    isPublicNetworkAddress(address);
