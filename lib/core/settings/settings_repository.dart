import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// Persistence failure for ordinary (non-secret) settings.
class SettingsRepositoryException implements Exception {
  const SettingsRepositoryException(this.operation, this.cause);

  final String operation;
  final Object cause;

  @override
  String toString() => 'SettingsRepositoryException($operation)';
}

abstract class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

/// Versioned, JSON-backed settings repository.
///
/// Reads are done through one typed [getAll] call. The async preferences API
/// omits values with an incompatible primitive type, which lets a damaged
/// field fall back independently while preserving all other valid fields.
class PreferencesSettingsRepository implements SettingsRepository {
  PreferencesSettingsRepository({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const String settingsKey = 'replica.settings.v2';
  static const String legacyJsonKey = 'settings';
  static const String legacyGuideKey = 'replica.guide_completed';
  static const String legacyLanguageKey = 'replica.language';
  static const String legacyThemeKey = 'replica.theme';

  final SharedPreferencesAsync _preferences;

  static const _readKeys = {
    settingsKey,
    legacyJsonKey,
    legacyGuideKey,
    legacyLanguageKey,
    legacyThemeKey,
  };

  @override
  Future<AppSettings> load() async {
    final values = await _readAll();
    final defaults = AppSettings.defaults();

    final currentRaw = values[settingsKey];
    if (currentRaw is String) {
      final decoded = _decodeMap(currentRaw);
      if (decoded != null) {
        final settings = AppSettings.fromJson(decoded, fallback: defaults);
        if (decoded['schemaVersion'] != AppSettings.currentSchemaVersion) {
          await save(settings);
        }
        return settings;
      }
      // A wholly malformed blob has no trustworthy fields. Keep it in place
      // for diagnostics and recover to defaults without deleting user data.
      return defaults;
    }

    final legacyRaw = values[legacyJsonKey];
    if (legacyRaw is String) {
      final decoded = _decodeMap(legacyRaw);
      if (decoded != null) {
        final settings = AppSettings.fromJson(decoded, fallback: defaults);
        await save(settings);
        return settings;
      }
    }

    final legacy = <String, dynamic>{
      if (values[legacyGuideKey] is bool)
        'guideCompleted': values[legacyGuideKey],
      if (values[legacyLanguageKey] is String)
        'languageTag': values[legacyLanguageKey],
      if (values[legacyThemeKey] is int) 'themeCode': values[legacyThemeKey],
    };
    if (legacy.isEmpty) return defaults;

    final settings = AppSettings.fromJson(legacy, fallback: defaults);
    await save(settings);
    return settings;
  }

  @override
  Future<void> save(AppSettings settings) async {
    try {
      await _preferences.setString(settingsKey, jsonEncode(settings.toJson()));
    } on Object catch (error) {
      throw SettingsRepositoryException('write', error);
    }
  }

  Future<Map<String, Object?>> _readAll() async {
    try {
      return await _preferences.getAll(allowList: _readKeys);
    } on Object catch (error) {
      throw SettingsRepositoryException('read', error);
    }
  }

  static Map<String, dynamic>? _decodeMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
