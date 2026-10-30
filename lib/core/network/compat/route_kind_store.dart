import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../log.dart';
import '../../settings/preference_keys.dart';
import 'network_contracts.dart';
import 'route_memory.dart';

/// Persists which route *kind* last worked per network identity — never
/// addresses (those live in [PixivFastRouteStore]) and never per-host.
/// On the next cold start on the same network, the persisted kinds seed the
/// group preference so the first request skips the discovery walk entirely.
///
/// A stale kind costs one failed tier attempt — the ladder invalidates a
/// seeded preference on failure exactly like a learned one, so a wrong hint
/// is self-correcting rather than sticky.
class RouteKindStore implements RouteKindMemory {
  RouteKindStore({required SharedPreferencesAsync preferences})
    : _preferences = preferences;

  static const storageKey = PreferenceKeys.routeKinds;

  /// Keep the last few identities only — a phone that has seen many
  /// networks must not grow the blob forever.
  static const _maxIdentities = 8;

  final SharedPreferencesAsync _preferences;
  Future<Map<String, Map<String, String>>>? _loadFuture;
  Future<void> _writeTail = Future<void>.value();

  /// Group→kind map for [networkIdentity], or null when nothing was
  /// persisted for it.
  @override
  Future<Map<String, String>?> kindsFor(String networkIdentity) async {
    return (await _load())[networkIdentity];
  }

  /// Serialized writes — several tiers can succeed concurrently during
  /// startup, and each success may flip a different group's preference.
  /// Callers do not wait: a failed write is logged. The cache takes the
  /// kind only once it is stored, so the next success writes it again.
  @override
  Future<void> remember(String networkIdentity, String group, String kind) {
    return _writeTail = _writeTail.then<void>((_) async {
      final all = await _load();
      if (all[networkIdentity]?[group] == kind) return;
      final next = {
        ...all,
        networkIdentity: {...?all[networkIdentity], group: kind},
      };
      while (next.length > _maxIdentities) {
        next.remove(next.keys.first);
      }
      try {
        await _preferences.setString(storageKey, jsonEncode(next));
        all
          ..clear()
          ..addAll(next);
      } on Object catch (error) {
        log('route kind not remembered: $error');
      }
    });
  }

  Future<Map<String, Map<String, String>>> _load() {
    return _loadFuture ??= _read();
  }

  Future<Map<String, Map<String, String>>> _read() async {
    try {
      final raw = await _preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, Map<String, String>>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final kinds = <String, String>{};
        for (final kindEntry in value.entries) {
          final kind = kindEntry.value;
          // Drop kinds that no longer exist rather than seeding a phantom
          // tier into the ladder.
          if (kind is String &&
              NetworkRouteKind.values.any((k) => k.name == kind)) {
            kinds[kindEntry.key] = kind;
          }
        }
        if (kinds.isNotEmpty) result[entry.key] = kinds;
      }
      return result;
    } on Object {
      return {};
    }
  }
}
