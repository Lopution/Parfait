import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/widgets/app_slider.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/features/novel/novel_reader_stage.dart';
import 'package:parfait/app/widgets/prompt_host.dart';

import 'helpers/novel_reader_harness.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart' show RecordingTranslationEngine;
import 'helpers/localized_app.dart';
import 'helpers/test_preferences.dart';
import 'helpers/view_size.dart';
import 'package:parfait/app/icons/app_icons.dart';

/// Stage-level test with a recording progress binding: pins the D1 write
/// gate — only user-committed turns reach `save`.
void main() {
  testWidgets('open and sheet toggles never write; a page turn writes once', (
    tester,
  ) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding));
    await pumpNovelLayout(tester);

    // First-layout echo and the restore jump do not persist anything.
    expect(binding.saves, isEmpty);
    expect(find.byType(PageView), findsOneWidget);

    // Open and close the info sheet — still no write.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.info));
    await tester.pumpAndSettle();
    expect(find.text('info sheet'), findsOneWidget);
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(binding.saves, isEmpty);

    // A real page turn writes exactly one anchor.
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    expect(binding.saves, hasLength(1));
  });

  testWidgets('scroll mode: open writes nothing, a settle writes once; '
      'turning pages on keeps the place', (tester) async {
    final text = List.generate(
      80,
      (index) => 'paragraph $index body text body text',
    ).join('\n');
    final binding = _RecordingBinding(
      restore: const NovelAnchor(paragraphId: 'p40', offset: 0),
    );
    await tester.pumpWidget(
      _stageApp(binding, text: text, pageTurn: NovelPageTurn.scroll),
    );
    await pumpNovelLayout(tester);
    expect(find.byType(PageView), findsNothing);
    expect(binding.saves, isEmpty);

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(binding.saves, hasLength(1));
    final read = binding.saves.single;
    expect(read, isNot(const NovelAnchor(paragraphId: 'p40', offset: 0)));

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.filter));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左右翻页'));
    await tester.pumpAndSettle();
    final layout = tester
        .widget<NovelReader>(find.byType(NovelReader))
        .handle!
        .layout!()!;
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      layout.pageIndexForAnchor(read),
    );
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
    await pumpNovelLayout(tester);

    // The restore jump reports the position as a layout echo — the store
    // keeps the record untouched until the user actually turns a page.
    expect(binding.saves, isEmpty);
    expect(binding.loadCalls, 1);
  });

  testWidgets('progress sheet: cancel leaves the reader untouched', (
    tester,
  ) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding));
    await pumpNovelLayout(tester);

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('阅读进度'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(AppSlider), const Offset(200, 0));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Back on the first page, nothing written.
    expect(binding.saves, isEmpty);
    expect(find.textContaining('1/'), findsWidgets);
  });

  testWidgets('the current reader hides the shell rail, under its panels '
      'too', (tester) async {
    await tester.pumpWidget(_stageApp(_RecordingBinding()));
    await tester.pump();
    final stage = find.byType(NovelReaderStage);
    final container = ProviderScope.containerOf(tester.element(stage));
    expect(container.read(shellRailHiddenProvider), isTrue);

    // A dialog over the reader leaves the text where it is.
    final navigator = Navigator.of(tester.element(stage));
    unawaited(
      showDialog<void>(
        context: tester.element(stage),
        useRootNavigator: false,
        builder: (_) => const SizedBox(),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(shellRailHiddenProvider), isTrue);
    navigator.pop();
    await tester.pumpAndSettle();

    // A page over the reader hands the rail back until it pops.
    unawaited(
      navigator.push(MaterialPageRoute<void>(builder: (_) => const SizedBox())),
    );
    await tester.pumpAndSettle();
    expect(container.read(shellRailHiddenProvider), isFalse);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(shellRailHiddenProvider), isTrue);
  });

  testWidgets('a failed prefs read surfaces an error with retry', (
    tester,
  ) async {
    final binding = _RecordingBinding()..loadError = StateError('prefs gone');
    await tester.pumpWidget(_stageApp(binding));
    await pumpNovelLayout(tester);

    // Error surface instead of an endless loading spinner.
    expect(find.text('读取设置失败'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);

    // Retry recovers once the store is healthy again.
    binding.loadError = null;
    await tester.tap(find.text('重试'));
    await pumpNovelLayout(tester);
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('a failed settings save surfaces a snackbar', (tester) async {
    await tester.pumpWidget(
      _stageApp(_RecordingBinding(), preferences: _FailingPreferences()),
    );
    await pumpNovelLayout(tester);

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.textDecrease));
    await pumpNovelLayout(tester);

    expect(shownPrompt, findsOneWidget);
    // The copy must say the change applied for this session only — the
    // old "保存失败" wording hid that the on-screen values were live.
    expect(find.text('阅读设置未能保存，仅本次生效'), findsOneWidget);

    // The in-memory value still applied — the snackbar reports the
    // persistence failure rather than silently dropping it. Dismiss it
    // programmatically so it stops covering the bottom bar.
    PromptHost.of(tester.element(find.byType(Scaffold).first)).hideCurrent();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.filter));
    await tester.pumpAndSettle();
    expect(find.text('16'), findsOneWidget);
  });

  testWidgets(
    'translate this page: translations under the paragraphs, on with each '
    'turn, gone once hidden',
    (tester) async {
      final engine = RecordingTranslationEngine((text) => '译 $text');
      await tester.pumpWidget(
        _stageApp(
          _RecordingBinding(),
          novel: _novelOfParagraphs(60),
          translation: engine,
        ),
      );
      await pumpNovelLayout(tester);

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻译本页'));
      await tester.pumpAndSettle();

      // The opening page, then the page ahead — never the whole book.
      expect(engine.sources.first, 'paragraph 0');
      expect(engine.sources.length, lessThan(60));
      expect(find.text('译 paragraph 0'), findsOneWidget);
      final translated = engine.sources.length;

      await tester.tapAt(const Offset(780, 300));
      await tester.pumpAndSettle();
      expect(engine.sources.length, greaterThan(translated));
      expect(find.textContaining('译 '), findsWidgets);

      await tester.tap(find.byTooltip('收起翻译'));
      await tester.pumpAndSettle();
      expect(find.textContaining('译 '), findsNothing);
    },
  );

  testWidgets(
    'iOS left-edge swipe pops NovelReaderStage even while chrome is visible and restores edgeToEdge',
    (tester) async {
      final systemUiModes = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
              systemUiModes.add(call.arguments as String);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      installPreferencesForTest(memoryPreferences({}));
      setViewSize(tester, const Size(400, 800));

      final container = ProviderContainer.test();
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: Builder(
            builder: (rootCtx) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(rootCtx).push<void>(
                  FuncPage<void>(
                    child: NovelReaderStage(
                      spec: NovelReaderStageSpec(
                        novel: _novel('reader ' * 200),
                        infoTooltip: 'info',
                        infoSheet: (_) => const Text('info sheet'),
                        progress: _RecordingBinding(),
                      ),
                    ),
                  ).createRoute(rootCtx),
                ),
                child: const Text('open-reader'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-reader'));
      await tester.pumpAndSettle();

      // Open chrome so _chromeVisible == true.
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect(find.byTooltip('info'), findsOneWidget);
      systemUiModes.clear();

      // Left-edge iOS swipe pops the reader and restores SystemUiMode.edgeToEdge.
      await tester.dragFrom(const Offset(12, 400), const Offset(280, 0));
      await tester.pumpAndSettle();
      expect(find.text('open-reader'), findsOneWidget);
      expect(find.byType(NovelReaderStage), findsNothing);
      expect(systemUiModes, contains('SystemUiMode.edgeToEdge'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('accessibleNavigation pins reader chrome open with canPop', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(_stageApp(_RecordingBinding(), chapters: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('info'), findsOneWidget);
    final popScope = tester.widget<PopScope<dynamic>>(
      find.byWidgetPredicate((w) => w is PopScope),
    );
    expect(popScope.canPop, isTrue);
  });

  testWidgets(
    'pointer cue keeps >=48dp hit target and ruby excludes reading from semantics',
    (tester) async {
      await tester.pumpWidget(
        _stageApp(
          _RecordingBinding(),
          text: '[[rb:漢字 > かんじ]] text ' * 40,
          inputModality: InputModality.pointer,
        ),
      );
      await tester.pumpAndSettle();
      final cueSize = tester.getSize(
        find.byKey(const ValueKey('novel-pointer-cue')),
      );
      expect(cueSize.width, greaterThanOrEqualTo(48));
      expect(cueSize.height, greaterThanOrEqualTo(48));

      final semantics = tester.ensureSemantics();
      try {
        expect(find.bySemanticsLabel(RegExp('漢字')), findsWidgets);
        expect(find.bySemanticsLabel(RegExp('かんじ')), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );
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
  var saveCalls = 0;
  Object? loadError;
  Object? saveError;

  @override
  Future<NovelAnchor?> load() async {
    loadCalls += 1;
    final error = loadError;
    if (error != null) throw error;
    return restore;
  }

  @override
  Future<void> save(NovelAnchor anchor) async {
    saveCalls += 1;
    final error = saveError;
    if (error != null) throw error;
    saves.add(anchor);
  }
}

Widget _stageApp(
  _RecordingBinding binding, {
  String? text,
  bool chapters = false,
  NovelEntity? novel,
  SharedPreferencesAsync? preferences,
  TranslationTransport? translation,
  NovelPageTurn pageTurn = NovelPageTurn.pages,
  InputModality? inputModality,
}) => buildNovelStageApp(
  binding,
  novel:
      novel ??
      (chapters
          ? _novelWithChapters()
          : testNovel(text ?? 'reader ' * 400, caption: '')),
  preferences: preferences,
  translation: translation,
  pageTurn: pageTurn,
  inputModality: inputModality,
);

NovelEntity _novel(String text) => testNovel(text, caption: '');

NovelEntity _novelOfParagraphs(int count) => NovelEntity(
  id: 79,
  title: 'Short paragraphs',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: count,
  contentVersion: 'short-$count',
  contentAvailable: true,
  paragraphs: [
    for (var i = 0; i < count; i++)
      NovelParagraph(id: 'p$i', text: 'paragraph $i'),
  ],
);

/// [count] chapter headings, each over a page of body text — the layout
/// surfaces them through `handle.chapters`.
NovelEntity _novelWithChapters([int count = 30]) => NovelEntity(
  id: 78,
  title: 'Chaptered novel',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: 1,
  contentVersion: 'chaptered-$count',
  contentAvailable: true,
  paragraphs: [
    for (var chapter = 1; chapter <= count; chapter++) ...[
      NovelParagraph(
        id: 'c$chapter',
        text: '第 $chapter 章',
        pageBreakBefore: true,
        isChapterHeading: true,
      ),
      for (var i = 0; i < 10; i++)
        NovelParagraph(
          id: 'c$chapter-$i',
          text: 'chapter $chapter body line $i ' * 4,
        ),
    ],
  ],
);
