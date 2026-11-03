import 'dart:io';

import '../network/compat/image_route_scores.dart';
import '../network/compat/network_fast_route_store.dart';
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
  WorkerFastRouteMemory(this._state, {this.onFastRouteLearned});

  final WorkerRouteMemoryState _state;
  final void Function(String host, String address)? onFastRouteLearned;

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
/// go back through [onSample] and [onRanges]: the main isolate's policy
/// learns them and its store persists them.
class WorkerImageRouteScoreMemory implements ImageRouteScoreMemory {
  WorkerImageRouteScoreMemory({this.onSample, this.onRanges});

  final void Function(String identity, ImageRouteSample sample)? onSample;
  final void Function(String identity, String candidate, bool served)? onRanges;

  var _identity = '';
  Map<String, ImageRouteScore> _scores = const {};

  /// Takes a config's scores, which are [networkIdentity]'s.
  void reseed(String networkIdentity, Map<String, ImageRouteScore> scores) {
    _identity = networkIdentity;
    _scores = scores;
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
  }) : fastRoutes = _parse(learnedFastRoutes),
       routeKinds = Map.of(routeKinds);

  final Map<String, InternetAddress> fastRoutes;
  final Map<String, String> routeKinds;

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
