import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../log.dart';
import '../../settings/preference_keys.dart';
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
/// an ECH config names change over time).
class ImageRouteScoreStore implements ImageRouteScoreMemory {
  ImageRouteScoreStore({
    required SharedPreferencesAsync preferences,
    DateTime Function()? clock,
  }) : _preferences = preferences,
       _clock = clock ?? DateTime.now;

  static const storageKey = PreferenceKeys.imageRouteScores;
  static const maxIdentities = 16;
  static const maxCandidates = 8;
  static const writeDelay = Duration(seconds: 10);

  final SharedPreferencesAsync _preferences;
  final DateTime Function() _clock;

  /// Boards by identity, the one used last at the end.
  Future<Map<String, ImageRouteScores>>? _loadFuture;
  Timer? _pendingWrite;

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

  /// Writes the changes still waiting for their [writeDelay], those
  /// waiting for the load included.
  Future<void> flush() async {
    await _load();
    final pending = _pendingWrite;
    if (pending == null) return;
    pending.cancel();
    _pendingWrite = null;
    await _write();
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
