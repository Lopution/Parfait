import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/core/novel/reader_settings.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/novel/novel_layout.dart';
import 'package:pixiv_func/features/novel/novel_reader.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'helpers/test_preferences.dart';

void main() {
  group('NovelReaderSettings', () {
    test('json round-trip keeps every field', () {
      const settings = NovelReaderSettings(
        fontSize: 21,
        lineHeight: 1.9,
        theme: NovelReaderTheme.night,
      );

      final restored = NovelReaderSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, Object?>,
      );

      expect(restored, settings);
    });

    test('copyWith clamps typography into the supported range', () {
      const settings = NovelReaderSettings();

      expect(settings.copyWith(fontSize: 4).fontSize, 12);
      expect(settings.copyWith(fontSize: 99).fontSize, 30);
      expect(settings.copyWith(lineHeight: 0.5).lineHeight, 1.3);
      expect(settings.copyWith(lineHeight: 9).lineHeight, 2.4);
    });

    test('theme parse falls back to system for unknown values', () {
      expect(NovelReaderTheme.parse('sepia'), NovelReaderTheme.sepia);
      expect(NovelReaderTheme.parse('bogus'), NovelReaderTheme.system);
      expect(NovelReaderTheme.parse(null), NovelReaderTheme.system);
    });
  });

  group('novelReaderPalette', () {
    test('system inherits the app theme; presets pin colors', () {
      final system = novelReaderPalette(NovelReaderTheme.system);
      expect(system.background, isNull);
      expect(system.foreground, isNull);

      final night = novelReaderPalette(NovelReaderTheme.night);
      expect(night.background, isNotNull);
      expect(night.foreground, isNotNull);
      expect(night.background!.computeLuminance(), lessThan(0.2));
    });
  });

  group('NovelReaderSettingsStore', () {
    test('save then load restores the settings', () async {
      installMemoryPreferences();
      final prefs = SharedPreferencesAsync();
      final store = NovelReaderSettingsStore(prefs);

      await store.save(
        const NovelReaderSettings(fontSize: 22, theme: NovelReaderTheme.sepia),
      );

      final loaded = await store.load();
      expect(loaded.fontSize, 22);
      expect(loaded.theme, NovelReaderTheme.sepia);
    });

    test('corrupt blob falls back to defaults', () async {
      installMemoryPreferences();
      final prefs = SharedPreferencesAsync();
      await prefs.setString('pixivfunc.novel.reader_settings.v1', '{broken');

      final loaded = await NovelReaderSettingsStore(prefs).load();
      expect(loaded, const NovelReaderSettings());
    });
  });

  group('NovelProgressStore', () {
    test('write then read restores the anchor payload', () async {
      installMemoryPreferences();
      final prefs = SharedPreferencesAsync();
      final store = NovelProgressStore(prefs);

      await store.write('acct-1', 77, paragraphId: 'p9', offset: 12);

      final saved = await store.read('acct-1', 77);
      expect(saved?.paragraphId, 'p9');
      expect(saved?.offset, 12);
    });

    test('entries are scoped per account and per novel', () async {
      installMemoryPreferences();
      final prefs = SharedPreferencesAsync();
      final store = NovelProgressStore(prefs);

      await store.write('acct-1', 77, paragraphId: 'p9', offset: 0);

      expect(await store.read('acct-2', 77), isNull);
      expect(await store.read('acct-1', 78), isNull);
      expect(await store.read('acct-1', 77), isNotNull);
    });

    test('evicts the stalest entries beyond the 200-entry cap', () async {
      installMemoryPreferences();
      final prefs = SharedPreferencesAsync();
      final store = NovelProgressStore(prefs);

      for (var index = 0; index < 205; index++) {
        await store.write('acct', index, paragraphId: 'p0', offset: 0);
      }

      // The first five novels were evicted; the most recent survive.
      expect(await store.read('acct', 0), isNull);
      expect(await store.read('acct', 4), isNull);
      expect(await store.read('acct', 204), isNotNull);
    });

    test('re-writing an existing entry renews its recency position', () async {
      installMemoryPreferences();
      final prefs = SharedPreferencesAsync();
      final store = NovelProgressStore(prefs);

      // Fill the map to the cap, then re-read the oldest entry — the
      // rewrite must reinsert it at the recency tail, not leave it at
      // the eviction front.
      for (var index = 0; index < 200; index++) {
        await store.write('acct', index, paragraphId: 'p0', offset: 0);
      }
      await store.write('acct', 0, paragraphId: 'p9', offset: 42);

      // One more novel pushes past the cap: novel 1 is now the stalest,
      // not the just-reread novel 0.
      await store.write('acct', 200, paragraphId: 'p0', offset: 0);

      final renewed = await store.read('acct', 0);
      expect(renewed?.paragraphId, 'p9');
      expect(renewed?.offset, 42);
      expect(await store.read('acct', 1), isNull);
      expect(await store.read('acct', 200), isNotNull);
    });
  });

  testWidgets('NovelReader restores the persisted anchor on first layout', (
    tester,
  ) async {
    // Enough paragraphs that p40 lands well past page one.
    final text = List.generate(
      80,
      (index) => 'paragraph $index body text body text',
    ).join('\n\n');
    var restoredPage = -1;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: NovelReader(
            novel: _novel(text),
            initialAnchor: const NovelAnchor(paragraphId: 'p60', offset: 0),
            onProgressChanged: (page, pageCount) => restoredPage = page,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(restoredPage, greaterThan(0));
  });
}

NovelEntity _novel(String text) => NovelEntity(
  id: 77,
  title: 'A novel',
  caption: 'caption',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: text.length,
  contentVersion: text,
  paragraphs: NovelContentMapper.fromText(text),
  contentAvailable: true,
);
