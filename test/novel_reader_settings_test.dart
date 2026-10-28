import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/features/novel/novel_reader_stage.dart';

import 'helpers/localized_app.dart';
import 'support/contrast.dart';

void main() {
  group('NovelReaderSettings', () {
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
    test('system inherits the app theme; presets pin their colors and the '
        'brightness they read as', () {
      final system = novelReaderPalette(NovelReaderTheme.system);
      expect(system.background, isNull);
      expect(system.foreground, isNull);
      expect(system.brightness, isNull);
      // The reader's system-bar icons invert off the brightness: a
      // recolored preset that forgets to repin it fails here.
      for (final theme in [
        NovelReaderTheme.paper,
        NovelReaderTheme.sepia,
        NovelReaderTheme.night,
      ]) {
        final palette = novelReaderPalette(theme);
        expect(palette.foreground, isNotNull, reason: '$theme');
        expect(
          palette.brightness,
          ThemeData.estimateBrightnessForColor(palette.background!),
          reason: '$theme brightness must track its background',
        );
      }
      final night = novelReaderPalette(NovelReaderTheme.night);
      expect(night.background!.computeLuminance(), lessThan(0.2));
    });

    test(
      'the progress hint keeps 4.5:1 and the pill outline 3:1 on every palette',
      () {
        final pairs = [
          for (final brightness in Brightness.values)
            (
              replicaTheme(brightness).colorScheme.onSurface,
              replicaTheme(brightness).scaffoldBackgroundColor,
            ),
          for (final theme in [
            NovelReaderTheme.paper,
            NovelReaderTheme.sepia,
            NovelReaderTheme.night,
          ])
            (
              novelReaderPalette(theme).foreground!,
              novelReaderPalette(theme).background!,
            ),
        ];
        for (final (text, page) in pairs) {
          final hint = Color.alphaBlend(
            text.withValues(alpha: novelReaderHintAlpha),
            page,
          );
          expect(contrastRatio(hint, page), greaterThanOrEqualTo(4.5));
          final outline = Color.alphaBlend(
            text.withValues(alpha: novelReaderPillOutlineAlpha),
            page,
          );
          expect(contrastRatio(outline, page), greaterThanOrEqualTo(3));
        }
      },
    );
  });

  group('NovelReaderSettingsStore', () {
    test('save then load restores every field', () async {
      final store = NovelReaderSettingsStore(SharedPreferencesAsync());
      // No field at its default, so a field the JSON drops shows.
      const settings = NovelReaderSettings(
        fontSize: 21,
        lineHeight: 1.9,
        theme: NovelReaderTheme.night,
      );

      await store.save(settings);
      expect(await store.load(), settings);
    });

    test('corrupt blob falls back to defaults', () async {
      final prefs = SharedPreferencesAsync();
      await prefs.setString('parfait.novel.reader_settings.v1', '{broken');

      final loaded = await NovelReaderSettingsStore(prefs).load();
      expect(loaded, const NovelReaderSettings());
    });
  });

  group('NovelProgressStore', () {
    test('entries are scoped per account and per novel', () async {
      final store = NovelProgressStore(SharedPreferencesAsync());

      await store.write('acct-1', 77, paragraphId: 'p9', offset: 12);

      expect(await store.read('acct-2', 77), isNull);
      expect(await store.read('acct-1', 78), isNull);
      final saved = await store.read('acct-1', 77);
      expect((saved?.paragraphId, saved?.offset), ('p9', 12));
    });

    test('re-writing an existing entry renews its recency position', () async {
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
      localizedApp(
        body: NovelReader(
          novel: _novel(text),
          initialAnchor: const NovelAnchor(paragraphId: 'p60', offset: 0),
          onProgressChanged: (page, pageCount) => restoredPage = page,
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
