import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/preference_keys.dart';
import '../settings/shared_preferences.dart';
import 'update_providers.dart';
import 'update_service.dart';

/// One-shot background update check (R2 — the pixes/skana convention: a
/// delayed single check after launch, silent on failure).
///
/// Throttled by [minInterval]: the timestamp is written *before* the
/// request so a failed check also consumes the window — retries never
/// spam the manifest endpoint. Silent callers only react to
/// [UpdateCheckStatus.available]; every other outcome is swallowed.
class UpdateAutoCheck {
  UpdateAutoCheck({
    required SharedPreferencesAsync preferences,
    required Future<UpdateService> Function() service,
    Duration? minInterval,
    DateTime Function()? clock,
  }) : _preferences = preferences,
       _service = service,
       _minInterval = minInterval ?? const Duration(hours: 24),
       _clock = clock ?? DateTime.now;

  final SharedPreferencesAsync _preferences;
  final Future<UpdateService> Function() _service;
  final Duration _minInterval;
  final DateTime Function() _clock;

  /// Runs the check when the throttle window has passed. Returns the
  /// result (or null when skipped/store-managed) so the caller can
  /// surface [UpdateCheckStatus.available] however it wants.
  Future<UpdateCheckResult?> checkOnce() async {
    final last =
        await _preferences.getInt(PreferenceKeys.updateAutoCheckAt) ?? 0;
    final now = _clock().millisecondsSinceEpoch;
    if (now - last < _minInterval.inMilliseconds) return null;

    await _preferences.setInt(PreferenceKeys.updateAutoCheckAt, now);
    final service = await _service();
    // Store-managed builds (F-Droid, non-Android) never self-check.
    if ((await service.capability()).storeManaged) return null;
    return service.check();
  }
}

final updateAutoCheckProvider = Provider<UpdateAutoCheck>(
  (ref) => UpdateAutoCheck(
    preferences: ref.watch(sharedPreferencesProvider),
    service: () => ref.read(updateServiceProvider.future),
  ),
);
