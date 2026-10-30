import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log.dart';
import '../settings/preference_keys.dart';
import '../settings/shared_preferences.dart';

/// The last artwork Hero flights that took an unexpected endpoint, one
/// line each, newest first, kept across restarts. The flight self-check
/// (`inspectHeroFlight`) writes them; the frame probe page shows, copies
/// and clears them. The fault seldom shows and cannot be recorded on
/// demand, so the log is always on.
class HeroAnomalyLog {
  HeroAnomalyLog(this._preferences);

  /// Entries kept; older ones fall off.
  static const capacity = 20;

  final SharedPreferencesAsync _preferences;

  /// Writes in order: two flights logged in one frame keep both lines.
  Future<void> _writes = Future.value();

  Future<List<String>> read() async =>
      await _preferences.getStringList(PreferenceKeys.heroAnomalies) ??
      const [];

  /// Called unawaited from a flight: a failed write is logged.
  Future<void> add(String entry) => _queue(() async {
    try {
      final entries = await read();
      await _preferences.setStringList(PreferenceKeys.heroAnomalies, [
        entry,
        ...entries.take(capacity - 1),
      ]);
    } on Object catch (error) {
      log('hero anomaly not recorded: $error');
    }
  });

  Future<void> clear() =>
      _queue(() => _preferences.remove(PreferenceKeys.heroAnomalies));

  /// Runs [write] after the writes before it; its failure is its caller's
  /// and the next write still runs.
  Future<void> _queue(Future<void> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.then((_) {}, onError: (Object _) {});
    return done;
  }
}

final heroAnomalyLogProvider = Provider<HeroAnomalyLog>(
  (ref) => HeroAnomalyLog(ref.watch(sharedPreferencesProvider)),
);
