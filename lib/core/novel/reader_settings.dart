import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/shared_preferences.dart';

/// Reader surface preset, legado-style. `system` follows the app theme; the
/// others pin a paper/eye-care/night palette inside the reader only.
enum NovelReaderTheme {
  system,
  paper,
  sepia,
  night;

  static NovelReaderTheme parse(String? raw) =>
      NovelReaderTheme.values.asNameMap()[raw] ?? NovelReaderTheme.system;
}

/// Resolved colors for one [NovelReaderTheme]. `null` fields mean "inherit
/// the app theme" (the `system` preset).
class NovelReaderPalette {
  const NovelReaderPalette({this.background, this.foreground});

  final Color? background;
  final Color? foreground;
}

NovelReaderPalette novelReaderPalette(NovelReaderTheme theme) {
  return switch (theme) {
    NovelReaderTheme.system => const NovelReaderPalette(),
    // Warm paper white — closest to a printed page in daylight.
    NovelReaderTheme.paper => const NovelReaderPalette(
      background: Color(0xFFF5F0E6),
      foreground: Color(0xFF2B2620),
    ),
    // Classic 绿豆沙 eye-care green used by legado/reading apps.
    NovelReaderTheme.sepia => const NovelReaderPalette(
      background: Color(0xFFC7E5C8),
      foreground: Color(0xFF22331F),
    ),
    NovelReaderTheme.night => const NovelReaderPalette(
      background: Color(0xFF101318),
      foreground: Color(0xFFC9CDD4),
    ),
  };
}

/// Persistent typography/surface choices for the novel reader. Every field
/// maps onto `NovelLayoutStyle` inputs — changing any of them triggers a
/// relayout, nothing else.
class NovelReaderSettings {
  const NovelReaderSettings({
    this.fontSize = 17,
    this.lineHeight = 1.7,
    this.theme = NovelReaderTheme.system,
  });

  final double fontSize;
  final double lineHeight;
  final NovelReaderTheme theme;

  static const minFontSize = 12.0;
  static const maxFontSize = 30.0;
  static const minLineHeight = 1.3;
  static const maxLineHeight = 2.4;

  NovelReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    NovelReaderTheme? theme,
  }) => NovelReaderSettings(
    fontSize: (fontSize ?? this.fontSize).clamp(minFontSize, maxFontSize),
    lineHeight: (lineHeight ?? this.lineHeight).clamp(
      minLineHeight,
      maxLineHeight,
    ),
    theme: theme ?? this.theme,
  );

  Map<String, Object?> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'theme': theme.name,
  };

  @override
  bool operator ==(Object other) =>
      other is NovelReaderSettings &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.theme == theme;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, theme);

  static NovelReaderSettings fromJson(Map<String, Object?> json) {
    return NovelReaderSettings(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 17,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.7,
      theme: NovelReaderTheme.parse(json['theme'] as String?),
    ).copyWith();
  }
}

/// SharedPreferences-backed store for [NovelReaderSettings] — one global
/// reader preference, not account-scoped (reading comfort is a device
/// choice, like the theme setting).
class NovelReaderSettingsStore {
  NovelReaderSettingsStore(this._preferences);

  static const _key = 'pixivfunc.novel.reader_settings.v1';

  final SharedPreferencesAsync _preferences;

  Future<NovelReaderSettings> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return const NovelReaderSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return NovelReaderSettings.fromJson(decoded);
      }
    } on FormatException {
      // A corrupt blob falls back to defaults rather than breaking reading.
    }
    return const NovelReaderSettings();
  }

  Future<void> save(NovelReaderSettings settings) {
    return _preferences.setString(_key, jsonEncode(settings.toJson()));
  }
}

/// Per-novel reading position, account-scoped like browsing history: the
/// key is `<accountId>:<novelId>` so an account switch never restores a
/// foreign position.
class NovelProgressStore {
  NovelProgressStore(this._preferences);

  static const _key = 'pixivfunc.novel.progress.v1';

  /// Entries beyond this cap are evicted oldest-first — a novel library is
  /// unbounded, the resume map must not be.
  static const _maxEntries = 200;

  final SharedPreferencesAsync _preferences;

  String _entryKey(String accountId, int novelId) => '$accountId:$novelId';

  Future<Map<String, Object?>> _readAll() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // Corrupt state: start clean instead of failing every reader open.
    }
    return {};
  }

  /// Returns the saved `NovelAnchor` payload as primitives — the typed
  /// `NovelAnchor` lives in the features layer (novel_layout), so the store
  /// hands back a record and the caller rebuilds the anchor.
  Future<({String paragraphId, int offset})?> read(
    String accountId,
    int novelId,
  ) async {
    final all = await _readAll();
    final entry = all[_entryKey(accountId, novelId)];
    if (entry is! Map<String, Object?>) return null;
    final paragraphId = entry['p'];
    final offset = entry['o'];
    if (paragraphId is! String || offset is! int || offset < 0) return null;
    return (paragraphId: paragraphId, offset: offset);
  }

  Future<void> write(
    String accountId,
    int novelId, {
    required String paragraphId,
    required int offset,
  }) async {
    final all = await _readAll();
    final key = _entryKey(accountId, novelId);
    // Insertion order is recency order for our purposes: re-saving an
    // entry must reinsert it at the end — a plain `all[key] =` keeps the
    // original position, so an often-reread novel would still be evicted
    // first. Removing before the write makes trimming from the front
    // genuinely drop the stalest.
    all.remove(key);
    all[key] = {'p': paragraphId, 'o': offset};
    while (all.length > _maxEntries) {
      all.remove(all.keys.first);
    }
    await _preferences.setString(_key, jsonEncode(all));
  }
}

final novelReaderSettingsStoreProvider = Provider<NovelReaderSettingsStore>(
  (ref) => NovelReaderSettingsStore(ref.watch(sharedPreferencesProvider)),
);

final novelProgressStoreProvider = Provider<NovelProgressStore>(
  (ref) => NovelProgressStore(ref.watch(sharedPreferencesProvider)),
);
