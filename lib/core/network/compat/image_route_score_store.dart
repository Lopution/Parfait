import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../log.dart';
import '../../settings/preference_keys.dart';
import 'image_route_discovery.dart';
import 'image_route_scores.dart';
import 'route_memory.dart';

/// Persists what pixiv's image route candidates scored on each network
/// identity, so a network the device has seen starts on the route that
/// served it last time.
///
/// It keeps a board per identity, fed every sample the app takes: the main
/// isolate's own and those the image worker forwards. A board answers at
/// once; the disk is written [writeDelay] after a change, so the samples
/// of a scroll cost one write. It keeps the [maxIdentities] networks used
/// last, each with the [maxCandidates] candidates sampled last (the fronts
/// an ECH config names change over time). What front discovery came to on
/// each of those networks is kept beside, under [discoveryKey].
class ImageRouteScoreStore implements ImageRouteScoreMemory {
  ImageRouteScoreStore({
    required SharedPreferencesAsync preferences,
    DateTime Function()? clock,
  }) : _preferences = preferences,
       _clock = clock ?? DateTime.now;

  static const storageKey = PreferenceKeys.imageRouteScores;
  static const discoveryKey = PreferenceKeys.imageRouteDiscovery;
  static const maxIdentities = 16;
  static const maxCandidates = 8;
  static const writeDelay = Duration(seconds: 10);

  final SharedPreferencesAsync _preferences;
  final DateTime Function() _clock;

  /// Boards by identity, the one used last at the end.
  Future<Map<String, ImageRouteScores>>? _loadFuture;
  Timer? _pendingWrite;

  /// Discoveries by identity, the one changed last at the end.
  Future<Map<String, ImageRouteDiscovery>>? _discoveryLoad;
  Timer? _pendingDiscoveryWrite;

  @override
  Future<Map<String, ImageRouteScore>> scoresFor(
    String networkIdentity,
  ) async => (await _load())[networkIdentity]?.snapshot() ?? const {};

  @override
  void record(String networkIdentity, ImageRouteSample sample) =>
      _change(networkIdentity, (board) => board.record(sample));

  @override
  void noteRanges(
    String networkIdentity,
    String candidate, {
    required bool served,
  }) => _change(
    networkIdentity,
    (board) => board.noteRanges(candidate, served: served),
  );

  @override
  Future<ImageRouteDiscovery?> discoveryFor(String networkIdentity) async =>
      (await _loadDiscoveries())[networkIdentity];

  @override
  void discovered(String networkIdentity, ImageRouteDiscovery discovery) {
    unawaited(
      _loadDiscoveries().then((discoveries) {
        discoveries
          ..remove(networkIdentity)
          ..[networkIdentity] = discovery;
        while (discoveries.length > maxIdentities) {
          discoveries.remove(discoveries.keys.first);
        }
        _pendingDiscoveryWrite ??= Timer(writeDelay, () {
          _pendingDiscoveryWrite = null;
          unawaited(_writeDiscoveries());
        });
      }),
    );
  }

  /// Writes the changes still waiting for their [writeDelay], those
  /// waiting for the load included.
  Future<void> flush() async {
    await _load();
    await _loadDiscoveries();
    final pending = _pendingWrite;
    if (pending != null) {
      pending.cancel();
      _pendingWrite = null;
      await _write();
    }
    final pendingDiscovery = _pendingDiscoveryWrite;
    if (pendingDiscovery != null) {
      pendingDiscovery.cancel();
      _pendingDiscoveryWrite = null;
      await _writeDiscoveries();
    }
  }

  /// Changes apply in call order: each waits on the same load.
  void _change(
    String networkIdentity,
    void Function(ImageRouteScores board) change,
  ) {
    unawaited(
      _load().then((boards) {
        final board =
            boards.remove(networkIdentity) ?? ImageRouteScores(clock: _clock);
        boards[networkIdentity] = board;
        change(board);
        while (boards.length > maxIdentities) {
          boards.remove(boards.keys.first);
        }
        _pendingWrite ??= Timer(writeDelay, () {
          _pendingWrite = null;
          unawaited(_write());
        });
      }),
    );
  }

  Future<void> _write() async {
    final boards = await _load();
    final json = {
      for (final MapEntry(key: identity, value: board) in boards.entries)
        identity: {
          for (final MapEntry(key: candidate, value: score)
              in (board.snapshot().entries.toList()
                    ..sort((a, b) => b.value.at.compareTo(a.value.at)))
                  .take(maxCandidates))
            candidate: score.toJson(),
        },
    };
    try {
      await _preferences.setString(storageKey, jsonEncode(json));
    } on Object catch (error) {
      log('image route scores not saved: $error');
    }
  }

  Future<void> _writeDiscoveries() async {
    final discoveries = await _loadDiscoveries();
    final json = {
      for (final MapEntry(:key, :value) in discoveries.entries)
        key: value.toJson(),
    };
    try {
      await _preferences.setString(discoveryKey, jsonEncode(json));
    } on Object catch (error) {
      log('image route discovery not saved: $error');
    }
  }

  Future<Map<String, ImageRouteDiscovery>> _loadDiscoveries() =>
      _discoveryLoad ??= _readDiscoveries();

  /// A damaged entry starts over.
  Future<Map<String, ImageRouteDiscovery>> _readDiscoveries() async {
    final discoveries = <String, ImageRouteDiscovery>{};
    try {
      final raw = await _preferences.getString(discoveryKey);
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      if (decoded is! Map) return discoveries;
      for (final MapEntry(key: identity, :value) in decoded.entries) {
        if (identity is String) {
          discoveries[identity] = ImageRouteDiscovery.fromJson(value);
        }
      }
    } on Object catch (error) {
      log('image route discovery not read: $error');
    }
    return discoveries;
  }

  Future<Map<String, ImageRouteScores>> _load() => _loadFuture ??= _read();

  /// A damaged entry is dropped and relearned.
  Future<Map<String, ImageRouteScores>> _read() async {
    final boards = <String, ImageRouteScores>{};
    try {
      final raw = await _preferences.getString(storageKey);
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      if (decoded is! Map) return boards;
      for (final MapEntry(key: identity, value: scores) in decoded.entries) {
        if (identity is! String || scores is! Map) continue;
        boards[identity] = ImageRouteScores(
          seed: {
            for (final MapEntry(key: candidate, value: score) in scores.entries)
              if (candidate is String)
                candidate: ?ImageRouteScore.fromJson(score),
          },
          clock: _clock,
        );
      }
    } on Object catch (error) {
      log('image route scores not read: $error');
    }
    return boards;
  }
}
