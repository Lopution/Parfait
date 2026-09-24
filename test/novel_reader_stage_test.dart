import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/core/novel/reader_settings.dart';
import 'package:pixiv_func/core/settings/shared_preferences.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/novel/novel_layout.dart';
import 'package:pixiv_func/features/novel/novel_reader_stage.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'helpers/test_preferences.dart';

/// Stage-level test with a recording progress binding: pins the D1 write
/// gate — only user-committed turns reach `save`.
void main() {
  // SharedPreferencesAsync reads through the platform instance — the
  // in-memory platform keeps reader-settings writes off the real plugin.
  installMemoryPreferences();

  testWidgets('open and sheet toggles never write; a page turn writes once', (
    tester,
  ) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // First-layout echo and the restore jump do not persist anything.
    expect(binding.saves, isEmpty);
    expect(find.byType(PageView), findsOneWidget);

    // Open and close the info sheet — still no write.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('info sheet'), findsOneWidget);
    await tester.tapAt(const Offset(400, 100));
    await tester.pumpAndSettle();
    expect(binding.saves, isEmpty);

    // A real page turn writes exactly one anchor.
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    expect(binding.saves, hasLength(1));
  });

  testWidgets('a stored record restores without being rewritten', (
    tester,
  ) async {
    final text = List.generate(
      80,
      (index) => 'paragraph $index body text body text',
    ).join('\n\n');
    final binding = _RecordingBinding(
      restore: const NovelAnchor(paragraphId: 'p60', offset: 0),
    );
    await tester.pumpWidget(_stageApp(binding, text: text));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The restore jump reports the position as a layout echo — the store
    // keeps the record untouched until the user actually turns a page.
    expect(binding.saves, isEmpty);
    expect(binding.loadCalls, 1);
  });

  testWidgets('settings sliders span exactly the model clamp range', (
    tester,
  ) async {
    await tester.pumpWidget(_stageApp(_RecordingBinding()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();

    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, hasLength(2));
    expect(sliders[0].min, NovelReaderSettings.minFontSize);
    expect(sliders[0].max, NovelReaderSettings.maxFontSize);
    expect(sliders[1].min, NovelReaderSettings.minLineHeight);
    expect(sliders[1].max, NovelReaderSettings.maxLineHeight);
  });

  testWidgets(
    'progress sheet: drag previews only; confirm lands without animation',
    (tester) async {
      final binding = _RecordingBinding();
      await tester.pumpWidget(_stageApp(binding));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('阅读进度'));
      await tester.pumpAndSettle();

      // Dragging the slider only moves the preview label — the reader
      // itself never leaves the current page and nothing persists.
      final slider = find.byType(Slider);
      expect(slider, findsOneWidget);
      final before = find
          .textContaining('·', findRichText: true)
          .evaluate()
          .length;
      await tester.drag(slider, const Offset(200, 0));
      await tester.pump();
      expect(binding.saves, isEmpty);
      // The page readout in the chrome/footer still shows the original
      // page — only the sheet's own preview label advanced.
      expect(find.text('确定'), findsOneWidget);
      expect(before, greaterThan(0));

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(binding.saves, hasLength(1));
    },
  );

  testWidgets('progress sheet: cancel leaves the reader untouched', (
    tester,
  ) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('阅读进度'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Back on the first page, nothing written.
    expect(binding.saves, isEmpty);
    expect(find.textContaining('1/'), findsWidgets);
  });

  testWidgets('progress sheet lists chapters and taps jump to their page', (
    tester,
  ) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding, chapters: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('阅读进度'));
    await tester.pumpAndSettle();

    expect(find.text('目录'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    await tester.tap(find.text('第二章'));
    await tester.pumpAndSettle();

    // The chapter tap jumped straight to its page — one user-committed
    // write for the landing anchor.
    expect(binding.saves, hasLength(1));
  });

  testWidgets('arrow keys turn pages with user-turn semantics', (tester) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(binding.saves, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(binding.saves, hasLength(2));
  });

  testWidgets('a failed prefs read surfaces an error with retry', (
    tester,
  ) async {
    final binding = _RecordingBinding()..loadError = StateError('prefs gone');
    await tester.pumpWidget(_stageApp(binding));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Error surface instead of an endless loading spinner.
    expect(find.text('读取设置失败'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);

    // Retry recovers once the store is healthy again.
    binding.loadError = null;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('a failed settings save surfaces a snackbar', (tester) async {
    await tester.pumpWidget(
      _stageApp(_RecordingBinding(), preferences: _FailingPreferences()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.text_decrease_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SnackBar), findsOneWidget);

    // The in-memory value still applied — the snackbar reports the
    // persistence failure rather than silently dropping it. Dismiss it
    // programmatically so it stops covering the bottom bar.
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    expect(find.text('16'), findsOneWidget);
  });

  testWidgets('progress sheet percent matches the footer formula at 1/2/N '
      'boundaries', (tester) async {
    // pageBreakBefore makes the page count deterministic — one short
    // paragraph per page regardless of layout metrics.
    NovelEntity paged(int pages) => NovelEntity(
      id: 77,
      title: 'A novel',
      caption: '',
      user: const UserEntity(id: 8, name: 'author', account: 'author'),
      tags: const [],
      textLength: 1,
      contentVersion: 'paged-$pages',
      contentAvailable: true,
      paragraphs: [
        for (var i = 0; i < pages; i++)
          NovelParagraph(id: 'pg$i', text: 'page $i', pageBreakBefore: i > 0),
      ],
    );

    Future<void> openSheet(int pages) async {
      // pumpWidget reuses the stage's Element across identical trees —
      // drop to an empty tree first so each page count mounts a fresh
      // stage with hidden chrome.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _stageApp(_RecordingBinding(), novel: paged(pages)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('阅读进度'));
      await tester.pumpAndSettle();
    }

    // One page: 100% regardless of formula.
    await openSheet(1);
    expect(find.text('1/1 · 100%'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Two pages: the preview starts on page 1 — the footer formula
    // reads 50% where the old position-over-range formula read 0%.
    await openSheet(2);
    expect(find.text('1/2 · 50%'), findsWidgets);
    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pump();
    expect(find.text('2/2 · 100%'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // N pages: page 1 of 4 shows the same 25% the footer reports.
    await openSheet(4);
    expect(find.text('1/4 · 25%'), findsWidgets);
  });
}

/// setString always fails — the in-memory platform still backs getString
/// so the settings load returns defaults.
class _FailingPreferences extends SharedPreferencesAsync {
  @override
  Future<void> setString(String key, String value) =>
      Future.error(StateError('disk full'));
}

class _RecordingBinding implements ReaderProgressBinding {
  _RecordingBinding({this.restore});

  final NovelAnchor? restore;
  final List<NovelAnchor> saves = [];
  var loadCalls = 0;
  Object? loadError;

  @override
  Future<NovelAnchor?> load() async {
    loadCalls += 1;
    final error = loadError;
    if (error != null) throw error;
    return restore;
  }

  @override
  Future<void> save(NovelAnchor anchor) async {
    saves.add(anchor);
  }
}

Widget _stageApp(
  _RecordingBinding binding, {
  String? text,
  bool chapters = false,
  NovelEntity? novel,
  SharedPreferencesAsync? preferences,
}) {
  return ProviderScope(
    overrides: [
      if (preferences != null)
        sharedPreferencesProvider.overrideWithValue(preferences),
    ],
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: NovelReaderStage(
          spec: NovelReaderStageSpec(
            novel:
                novel ??
                (chapters
                    ? _novelWithChapters()
                    : _novel(text ?? 'reader ' * 400)),
            infoTooltip: 'info',
            infoSheet: (context) => const Text('info sheet'),
            progress: binding,
          ),
        ),
      ),
    ),
  );
}

NovelEntity _novel(String text) => NovelEntity(
  id: 77,
  title: 'A novel',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: text.length,
  contentVersion: text,
  paragraphs: NovelContentMapper.fromText(text),
  contentAvailable: true,
);

/// Two chapter headings embedded in enough body text to span pages — the
/// layout surfaces them through `handle.chapters`.
NovelEntity _novelWithChapters() => NovelEntity(
  id: 78,
  title: 'Chaptered novel',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: 1,
  contentVersion: 'chaptered',
  contentAvailable: true,
  paragraphs: [
    const NovelParagraph(
      id: 'c1',
      text: '第一章',
      pageBreakBefore: true,
      isChapterHeading: true,
    ),
    for (var i = 0; i < 120; i++)
      NovelParagraph(id: 'a$i', text: 'chapter one body line $i ' * 4),
    const NovelParagraph(
      id: 'c2',
      text: '第二章',
      pageBreakBefore: true,
      isChapterHeading: true,
    ),
    for (var i = 0; i < 120; i++)
      NovelParagraph(id: 'b$i', text: 'chapter two body line $i ' * 4),
  ],
);
