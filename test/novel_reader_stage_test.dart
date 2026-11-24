import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/widgets/app_slider.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/settings/shared_preferences.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/features/novel/novel_reader_stage.dart';
import 'package:parfait/app/widgets/prompt_host.dart';

import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart' show RecordingTranslationEngine;
import 'helpers/localized_app.dart';
import 'helpers/test_preferences.dart';
import 'helpers/view_size.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';

/// Stage-level test with a recording progress binding: pins the D1 write
/// gate — only user-committed turns reach `save`.
void main() {
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The restore jump reports the position as a layout echo — the store
    // keeps the record untouched until the user actually turns a page.
    expect(binding.saves, isEmpty);
    expect(binding.loadCalls, 1);
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
      final slider = find.byType(AppSlider);
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

  testWidgets('a turned phone fits the progress and settings sheets', (
    tester,
  ) async {
    setViewSize(tester, const Size(896, 411));
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding, chapters: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(448, 200));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('阅读进度'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final sheet = tester.getRect(find.byType(AppBottomSheet));
    expect(sheet.contains(tester.getCenter(find.text('确定'))), isTrue);
    expect(
      find.descendant(
        of: find.byType(AppBottomSheet),
        matching: find.text('第 1 章'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // The last row, the reading theme, scrolls into reach.
    await tester.ensureVisible(find.text('夜间'));
    await tester.pumpAndSettle();
    expect(
      tester
          .getRect(find.byType(AppBottomSheet))
          .contains(tester.getCenter(find.text('夜间'))),
      isTrue,
    );
  });

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

    await tester.drag(find.byType(AppSlider), const Offset(200, 0));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Back on the first page, nothing written.
    expect(binding.saves, isEmpty);
    expect(find.textContaining('1/'), findsWidgets);
  });

  testWidgets('progress sheet: the chapter you are in is marked and in '
      'view; a chapter tap goes there', (tester) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding, chapters: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    Future<void> openSheet() async {
      if (find.bySemanticsLabel('阅读进度').evaluate().isEmpty) {
        await tester.tapAt(const Offset(400, 300));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.bySemanticsLabel('阅读进度'));
      await tester.pumpAndSettle();
    }

    ListTile row(String title) => tester.widget<ListTile>(
      find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
    );
    final list = find.byType(ListView);

    await openSheet();
    expect(row('第 1 章').selected, isTrue);
    expect(find.text('第 30 章'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('第 30 章'),
      200,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    await tester.tap(find.text('第 30 章'));
    await tester.pumpAndSettle();
    expect(find.text('第 30 章'), findsOneWidget, reason: 'its heading');
    expect(binding.saves, hasLength(1));

    await openSheet();
    expect(row('第 30 章').selected, isTrue);
    expect(
      tester.getRect(list).contains(tester.getCenter(find.text('第 30 章').last)),
      isTrue,
    );
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

  testWidgets('chrome and page turns keep the reader and its lines', (
    tester,
  ) async {
    await tester.pumpWidget(_stageApp(_RecordingBinding()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    NovelReader reader() => tester.widget(find.byType(NovelReader));
    Widget firstLine() => tester.widget(
      find
          .descendant(of: find.byType(PageView), matching: find.byType(Text))
          .first,
    );
    final opened = reader();

    // The chrome shows over the same lines.
    final line = firstLine();
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.byIcon(AppIcons.info), findsOneWidget);
    expect(firstLine(), same(line));
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    // A drag past the middle reports the next page; the page leaving
    // keeps its lines.
    final gesture = await tester.startGesture(const Offset(700, 300));
    // The first move only claims the drag.
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-460, 0));
    await tester.pump();
    expect(find.textContaining('2/'), findsOneWidget);
    expect(firstLine(), same(line));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reader(), same(opened));
  });

  Finder progressHint() => find.ancestor(
    of: find.textContaining(RegExp(r'^ · \d+/\d+ · \d+%')),
    matching: find.byType(MergeSemantics),
  );

  testWidgets('the immersive progress hint stays on the article column', (
    tester,
  ) async {
    setViewSize(tester, const Size(1200, 800));
    await tester.pumpWidget(_stageApp(_RecordingBinding()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final hint = tester.getRect(progressHint());
    const columnLeft = (1200 - ContentWidths.article) / 2;
    expect(hint.left, greaterThanOrEqualTo(columnLeft));
    expect(hint.right, lessThanOrEqualTo(1200 - columnLeft));
    expect(hint.center.dx, closeTo(600, .5));
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
    await tester.tap(find.byIcon(AppIcons.textDecrease));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

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
    'desktop arrow, page, and space keys navigate pages and scroll column',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final binding = _RecordingBinding();
      await tester.pumpWidget(
        _stageApp(binding, novel: _novelOfParagraphs(160)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      Future<void> pressShiftSpace() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }

      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(binding.saves, hasLength(3));

      await pressShiftSpace();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(binding.saves, hasLength(6));

      await tester.pumpWidget(
        _stageApp(
          _RecordingBinding(),
          novel: _novelOfParagraphs(160),
          pageTurn: NovelPageTurn.scroll,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;

      expect(offset(), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final afterArrow = offset();
      expect(afterArrow, greaterThan(0));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      final afterPage = offset();
      expect(afterPage, greaterThan(afterArrow));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(offset(), greaterThan(afterPage));

      final beforeUp = offset();
      await pressShiftSpace();
      await tester.pumpAndSettle();
      expect(offset(), lessThan(beforeUp));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'desktop pointer shows anchored settings popover and progress/info side sheets',
    (tester) async {
      setViewSize(tester, const Size(1100, 800));

      await tester.pumpWidget(
        _stageApp(_RecordingBinding(), novel: _novelWithChapters(4)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tapAt(const Offset(550, 400), kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();

      Rect panelRect(Finder content) => tester.getRect(
        find.ancestor(of: content, matching: find.byType(Material)).first,
      );

      await tester.tap(
        find.byIcon(AppIcons.filter),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppBottomSheet), findsNothing);
      final settingsRect = panelRect(find.text('字号'));
      expect(settingsRect.width, lessThanOrEqualTo(380));
      expect(settingsRect.right, greaterThan(700));
      await tester.tapAt(const Offset(20, 20), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byIcon(UiIcons.expandLess),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppBottomSheet), findsNothing);
      final progressRect = panelRect(find.text('阅读进度'));
      expect(progressRect.width, lessThanOrEqualTo(400));
      expect(progressRect.right, closeTo(1100, 1));
      await tester.tapAt(const Offset(20, 20), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byIcon(AppIcons.info),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppBottomSheet), findsNothing);
      final infoRect = panelRect(find.text('info sheet'));
      expect(infoRect.width, lessThanOrEqualTo(400));
      expect(infoRect.right, closeTo(1100, 1));
      await tester.tapAt(const Offset(20, 20), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('info sheet'), findsNothing);

      setViewSize(tester, const Size(500, 800));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(NovelReaderStage)).width, 500);
      await tester.tap(
        find.byIcon(AppIcons.filter),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('字号'), findsOneWidget);
      expect(find.byType(AppBottomSheet), findsOneWidget);
      await tester.tapAt(const Offset(20, 20), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'book posture spreads two pages around the hinge and pins the footer hint to the left half',
    (tester) async {
      setViewSize(tester, const Size(884, 740));
      tester.view.displayFeatures = const [
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(436, 0, 12, 740),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      addTearDown(() => tester.view.displayFeatures = const []);

      await tester.pumpWidget(_stageApp(_RecordingBinding()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final pageTexts = find.descendant(
        of: find.byType(PageView),
        matching: find.byType(Text),
      );
      final rects = [
        for (final element in pageTexts.evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ];
      final leftSide = rects.where((r) => r.center.dx < 436).toList();
      final rightSide = rects.where((r) => r.center.dx > 448).toList();
      expect(leftSide, isNotEmpty);
      expect(rightSide, isNotEmpty);
      for (final rect in leftSide) {
        expect(rect.right, lessThanOrEqualTo(436));
      }
      for (final rect in rightSide) {
        expect(rect.left, greaterThanOrEqualTo(448));
      }

      final hint = tester.getRect(progressHint());
      expect(hint.right, lessThanOrEqualTo(436));
    },
  );

  testWidgets(
    'pointer reader shows bottom-strip cue clear of body text and restores chrome on tap',
    (tester) async {
      for (final size in const [Size(600, 800), Size(1100, 800)]) {
        setViewSize(tester, size);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _stageApp(_RecordingBinding(), inputModality: InputModality.pointer),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final cue = find.byKey(const ValueKey('novel-pointer-cue'));
        expect(cue, findsOneWidget);
        expect(find.byIcon(AppIcons.info), findsNothing);
        final cueRect = tester.getRect(cue);
        final readerText = find.descendant(
          of: find.byType(NovelReader),
          matching: find.byType(RichText),
        );
        for (final element in readerText.evaluate()) {
          final box = element.renderObject! as RenderBox;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          expect(
            cueRect.overlaps(rect),
            isFalse,
            reason: 'cue $cueRect must not overlap body text $rect at $size',
          );
        }

        await tester.tap(cue, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        expect(find.byIcon(AppIcons.info), findsOneWidget);
        expect(cue, findsNothing);
      }
    },
  );

  testWidgets(
    'even-page wide spread reaches 100%, highlights last chapter, and bookmarks right leaf',
    (tester) async {
      setViewSize(tester, const Size(1100, 700));
      final novel = _novel('').withWebContent(
        '[chapter:第一章]\nP1[newpage][chapter:第二章]\nP2[newpage][chapter:第三章]\nP3[newpage][chapter:第四章]\nP4',
      );
      int? writtenMarker;
      final markerPageProvider = Provider<int?>((_) => null);
      final markerPendingProvider = Provider<bool>((_) => false);
      final binding = _RecordingBinding();
      await tester.pumpWidget(
        _stageApp(
          binding,
          novel: novel,
          pageTurn: NovelPageTurn.pages,
          spreadMode: NovelSpreadMode.auto,
          marker: NovelMarkerBinding(
            page: markerPageProvider,
            pending: markerPendingProvider,
            write: (page) async => writtenMarker = page,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('2/4 · 50%'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.textContaining('4/4 · 100%'), findsOneWidget);

      await tester.tapAt(const Offset(550, 350));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('阅读进度'));
      await tester.pumpAndSettle();
      final lastChapterTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('第四章'), matching: find.byType(ListTile)),
      );
      expect(lastChapterTile.selected, isTrue);

      await tester.tap(find.text('在此页加书签'));
      await tester.pumpAndSettle();
      expect(writtenMarker, 4);
    },
  );

  testWidgets(
    'key repeat turns pages without animation and settings sliders persist onChangeEnd',
    (tester) async {
      final prefs = _CountingPreferences();
      final novel = _novel(
        '',
      ).withWebContent('P1\n[newpage]\nP2\n[newpage]\nP3\n[newpage]\nP4');
      await tester.pumpWidget(
        _stageApp(
          _RecordingBinding(),
          novel: novel,
          preferences: prefs,
          pageTurn: NovelPageTurn.pages,
          spreadMode: NovelSpreadMode.off,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // KeyRepeatEvent jumps immediately without resetting a 300ms animation.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('P4'), findsOneWidget);

      // Font-size slider has 18 integer steps and persists only on onChangeEnd.
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      final sliders = tester
          .widgetList<AppSlider>(find.byType(AppSlider))
          .toList();
      expect(sliders, hasLength(2));
      expect(sliders[0].divisions, 18);
      expect(sliders[1].divisions, 11);

      final writesBefore = prefs.writtenValues.length;
      sliders[0].onChanged!(20.0);
      await tester.pump();
      expect(find.text('20'), findsOneWidget);
      expect(prefs.writtenValues.length, writesBefore);

      sliders[0].onChangeEnd!(20.0);
      await tester.pump();
      expect(prefs.writtenValues.length, writesBefore + 1);

      sliders[1].onChanged!(2.0);
      await tester.pump();
      expect(prefs.writtenValues.length, writesBefore + 1);
      sliders[1].onChangeEnd!(2.0);
      await tester.pumpAndSettle();
      expect(prefs.writtenValues.length, writesBefore + 2);
    },
  );

  testWidgets(
    'bilingual mode batches both spread leaves and skips scrolled-past paragraphs in scroll mode',
    (tester) async {
      // Wide spread: first batch translates both page 0 and page 1 together,
      // then prewarms pages 2 and 3.
      setViewSize(tester, const Size(1100, 700));
      final spreadEngine = _BatchRecordingTranslationEngine();
      final spreadNovel = _novel('').withWebContent(
        'LEFT1\n[newpage]\nRIGHT2\n[newpage]\nLEFT3\n[newpage]\nRIGHT4',
      );
      await tester.pumpWidget(
        _stageApp(
          _RecordingBinding(),
          novel: spreadNovel,
          translation: spreadEngine,
          pageTurn: NovelPageTurn.pages,
          spreadMode: NovelSpreadMode.auto,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(550, 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻译本页'));
      await tester.pumpAndSettle();

      expect(spreadEngine.batches.first, ['LEFT1', 'RIGHT2']);
      expect(spreadEngine.batches[1], ['LEFT3', 'RIGHT4']);

      // Scroll mode: scrolled-past paragraphs above viewport anchor are skipped.
      setViewSize(tester, const Size(800, 600));
      await tester.pumpWidget(const SizedBox.shrink());
      final scrollEngine = _BatchRecordingTranslationEngine();
      await tester.pumpWidget(
        _stageApp(
          _RecordingBinding(),
          novel: _novelOfParagraphs(80),
          translation: scrollEngine,
          pageTurn: NovelPageTurn.scroll,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final list = tester.widget<ListView>(find.byType(ListView));
      list.controller!.jumpTo(260);
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻译本页'));
      await tester.pumpAndSettle();

      expect(scrollEngine.batches, isNotEmpty);
      expect(scrollEngine.batches.first, isNot(contains('paragraph 0')));
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
}

class _CountingPreferences extends SharedPreferencesAsync {
  final List<String> writtenValues = [];

  @override
  Future<void> setString(String key, String value) {
    writtenValues.add(value);
    return super.setString(key, value);
  }
}

class _BatchRecordingTranslationEngine implements TranslationTransport {
  final List<List<String>> batches = [];

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async =>
      (await translateAll([text], targetLanguage: targetLanguage)).single;

  @override
  Future<List<String>> translateAll(
    List<String> sources, {
    required String targetLanguage,
  }) async {
    batches.add(List<String>.of(sources));
    return [for (final source in sources) '译 $source'];
  }
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
  ThemeData? theme,
  TranslationTransport? translation,
  NovelPageTurn pageTurn = NovelPageTurn.pages,
  NovelSpreadMode spreadMode = NovelSpreadMode.auto,
  InputModality? inputModality,
  NovelMarkerBinding? marker,
}) {
  installPreferencesForTest(
    memoryPreferences({
      'parfait.novel.reader_settings.v1': jsonEncode(
        NovelReaderSettings(
          pageTurn: pageTurn,
          spreadMode: spreadMode,
        ).toJson(),
      ),
    }),
  );
  final stage = NovelReaderStage(
    spec: NovelReaderStageSpec(
      novel:
          novel ??
          (chapters ? _novelWithChapters() : _novel(text ?? 'reader ' * 400)),
      infoTooltip: 'info',
      infoSheet: (context) => const Text('info sheet'),
      progress: binding,
      marker: marker,
    ),
  );
  return localizedApp(
    overrides: [
      if (preferences != null)
        sharedPreferencesProvider.overrideWithValue(preferences),
      if (translation != null)
        translationServiceProvider.overrideWithValue(translation),
    ],
    builder: promptHostBuilder,
    theme: theme,
    body: inputModality == null
        ? stage
        : InputModalityScope(initialModality: inputModality, child: stage),
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
