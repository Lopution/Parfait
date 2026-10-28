import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;

import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/feed/feed_text_warmup.dart';

import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'helpers/localized_app.dart';
import 'helpers/warm_text.dart';

void main() {
  test(
    'Novel mapper keeps paragraphs, ruby marks and unknown marks visible',
    () {
      final paragraphs = NovelContentMapper.fromText(
        '第一[[rb:漢字 > かんじ]]\n\n未知 [[future:payload]]',
      );

      expect(paragraphs, hasLength(3));
      expect(paragraphs[0].text, '第一漢字');
      expect(paragraphs[0].inlineMarks.single.kind, 'rb');
      expect(paragraphs[0].inlineMarks.single.value, 'かんじ');
      expect(paragraphs[1].text, isEmpty);
      expect(paragraphs[2].text, '未知 [[future:payload]]');
      expect(paragraphs[2].inlineMarks.single.isUnknown, isTrue);
    },
  );

  test('Novel detail mapper keeps metadata and versions JSON body content', () {
    final first = NovelEntity.fromDetailJson(_novelJson('hello'));
    final second = NovelEntity.fromDetailJson(_novelJson('hello again'));

    expect(first.id, 77);
    expect(first.title, 'A novel');
    expect(first.user.name, 'author');
    expect(first.seriesId, 12);
    expect(first.tags.single.translatedName, 'tag translated');
    expect(first.contentAvailable, isTrue);
    expect(first.paragraphs.single.text, 'hello');
    expect(first.contentVersion, isNot(second.contentVersion));
  });

  test('layout cache is keyed by content, viewport and typography', () {
    final cache = NovelLayoutCache(maxEntries: 2);
    final engine = NovelLayoutEngine(cache: cache);
    final paragraphs = [
      for (var index = 0; index < 80; index++)
        NovelParagraph(id: 'p$index', text: 'paragraph $index ' * 8),
    ];
    const style = NovelLayoutStyle(fontSize: 14, lineHeight: 1.4);

    final first = engine.layout(
      paragraphs: paragraphs,
      contentVersion: 'v1',
      viewport: const Size(180, 160),
      style: style,
      textColor: Colors.black,
      brightness: Brightness.light,
    );
    final cached = engine.layout(
      paragraphs: paragraphs,
      contentVersion: 'v1',
      viewport: const Size(180, 160),
      style: style,
      textColor: Colors.black,
      brightness: Brightness.light,
    );
    final changedViewport = engine.layout(
      paragraphs: paragraphs,
      contentVersion: 'v1',
      viewport: const Size(240, 160),
      style: style,
      textColor: Colors.black,
      brightness: Brightness.light,
    );

    expect(first.pages.length, greaterThan(1));
    expect(identical(first, cached), isTrue);
    expect(changedViewport.key.viewport, const Size(240, 160));
    expect(cache.length, 2);
    expect(first.progressPercent(0), 0);
    expect(first.progressPercent(first.pages.length - 1), 100);
    expect(
      first.pageIndexForAnchor(first.pages.last.startAnchor),
      first.pages.length - 1,
    );
  });

  test(
    'a translation lays out under its paragraph and moves no anchor',
    () async {
      final engine = NovelLayoutEngine();
      final paragraphs = [
        for (var index = 0; index < 40; index++)
          NovelParagraph(id: 'p$index', text: 'paragraph $index ' * 4),
      ];
      Future<NovelLayout> layout(Map<String, String> translations) =>
          engine.layoutCancellable(
            paragraphs: paragraphs,
            contentVersion: 'v1',
            viewport: const Size(240, 320),
            style: const NovelLayoutStyle(),
            textColor: Colors.black,
            brightness: Brightness.light,
            translations: translations,
          );

      final plain = await layout(const {});
      // An empty translation (already in the target language) shows nothing.
      final bilingual = await layout(const {
        'p0': 'translation zero',
        'p1': '',
      });

      final lines = [for (final page in bilingual.pages) ...page.lines];
      final translated = lines.where((line) => line.isTranslation).toList();
      expect(translated.map((line) => line.paragraphId).toSet(), {'p0'});
      expect(translated.first.startOffset, paragraphs.first.text.length);
      final original = lines[lines.indexOf(translated.first) - 1];
      expect(original.paragraphId, 'p0');
      expect(original.spacingAfter, const NovelLayoutStyle().translationGap);
      expect(bilingual.key, isNot(plain.key));
      expect(bilingual.totalCharacters, plain.totalCharacters);
      expect(bilingual.pages.last.endCharacter, plain.pages.last.endCharacter);
    },
  );

  test('reader tap zones and page progress are bounded and monotonic', () {
    final reader = NovelReaderController(pageCount: 4);

    expect(reader.zoneForTap(0, 100), NovelTapZone.previous);
    expect(reader.zoneForTap(29, 100), NovelTapZone.previous);
    expect(reader.zoneForTap(50, 100), NovelTapZone.center);
    expect(reader.zoneForTap(71, 100), NovelTapZone.next);
    expect(reader.zoneForTap(100, 100), NovelTapZone.next);
    expect(reader.handleTap(50, 100), isFalse);
    expect(reader.currentPage, 0);
    expect(reader.handleTap(90, 100), isTrue);
    expect(reader.currentPage, 1);
    expect(reader.progressPercent, closeTo(33.333, 0.01));
    reader.setPage(99);
    expect(reader.currentPage, 3);
    expect(reader.progressPercent, 100);
    expect(reader.next(), isFalse);
  });

  test(
    'layout cancellation is observable instead of returning stale pages',
    () async {
      final token = CancelToken()..cancel();
      final engine = NovelLayoutEngine();

      await expectLater(
        engine.layoutCancellable(
          paragraphs: [
            for (var index = 0; index < 20; index++)
              NovelParagraph(id: 'p$index', text: 'body'),
          ],
          contentVersion: 'v1',
          viewport: const Size(240, 320),
          style: const NovelLayoutStyle(),
          textColor: Colors.black,
          brightness: Brightness.light,
          cancelToken: token,
        ),
        throwsA(isA<ApiCancelled>()),
      );
    },
  );

  testWidgets('NovelReader exposes PageView, center tap and edge paging', (
    tester,
  ) async {
    var centerTaps = 0;
    final handle = NovelReaderHandle();
    var pages = 0;
    await tester.pumpWidget(
      localizedApp(
        body: NovelReader(
          novel: _novel('reader ' * 400),
          handle: handle,
          onCenterTap: () => centerTaps += 1,
          onProgressChanged: (page, pageCount) => pages = pageCount,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(PageView), findsOneWidget);
    expect(pages, greaterThan(0));

    // Center zone toggles chrome instead of turning a page.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 250));
    expect(centerTaps, 1);
    expect(handle.currentPage?.call(), 0);

    // Right edge turns forward; left edge turns back. The logical page is
    // written by PageView.onPageChanged once the turn animation settles.
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    expect(handle.currentPage?.call(), 1);
    await tester.tapAt(const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(handle.currentPage?.call(), 0);
  });

  testWidgets('large system text is laid out as wide as it paints', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final pageCounts = <double, int>{};
    for (final scale in [1.0, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(
        localizedApp(
          body: NovelReader(
            novel: _novel('reader ' * 400),
            onProgressChanged: (_, count) => pageCounts[scale] = count,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The body really is larger, not only measured as it paints.
    expect(pageCounts[2.0], greaterThan(pageCounts[1.0]!));

    final lines = tester.renderObjectList<RenderParagraph>(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(RichText),
      ),
    );
    expect(lines, isNotEmpty);
    for (final line in lines) {
      expect(
        line.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(line.size.width + 0.5),
        reason: line.text.toPlainText(),
      );
    }
  });

  testWidgets('the pages beside the page on screen are built at rest', (
    tester,
  ) async {
    final handle = NovelReaderHandle();
    await tester.pumpWidget(
      localizedApp(
        body: NovelReader(
          novel: _novel([for (var i = 0; i < 1200; i++) 'w$i'].join(' ')),
          handle: handle,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final pages = handle.layout!()!.pages;
    expect(pages.length, greaterThan(3));
    Finder firstLine(int page) => find.text(
      pages[page].lines.firstWhere((line) => line.text.isNotEmpty).text,
      skipOffstage: false,
    );
    expect(firstLine(1), findsOneWidget);
    expect(firstLine(2), findsNothing);

    // Mid-swipe nothing new is built; the page after waits for the landing.
    final swipe = await tester.startGesture(const Offset(600, 300));
    await swipe.moveBy(const Offset(-40, 0));
    await tester.pump();
    await swipe.moveBy(const Offset(-460, 0));
    await tester.pump();
    expect(firstLine(2), findsNothing);
    await swipe.up();
    await tester.pumpAndSettle();
    expect(handle.currentPage?.call(), 1);
    expect(firstLine(0), findsOneWidget);
    expect(firstLine(2), findsOneWidget);
  });

  for (final word in ['ある日の物語', '某日的故事']) {
    testWidgets('at rest the pages two away are queued as their lines lay '
        'out ($word)', (tester) async {
      final warmup = _RecordingWarmup();
      final handle = NovelReaderHandle();
      final settings = ValueNotifier(const NovelReaderSettings());
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        localizedApp(
          body: ValueListenableBuilder(
            valueListenable: settings,
            builder: (_, value, _) => NovelReader(
              novel: _novel([for (var i = 0; i < 900; i++) '$word$i'].join()),
              settings: value,
              handle: handle,
              textWarmup: warmup,
            ),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      await settle();
      List<String> linesOf(int page) => [
        for (final line in handle.layout!()!.pages[page].lines)
          if (line.text.isNotEmpty) line.text,
      ];
      expect(warmup.queued.keys, [2]);
      final ahead = warmup.queued[2]!;
      expect([for (final line in ahead) line.span.text], linesOf(2));

      // Nothing is queued mid-swipe; the landing queues around page 1.
      final swipe = await tester.startGesture(const Offset(600, 300));
      await swipe.moveBy(const Offset(-40, 0));
      await swipe.moveBy(const Offset(-460, 0));
      await tester.pump();
      expect(warmup.queued, isEmpty);
      await swipe.up();
      await tester.pumpAndSettle();
      expect(warmup.queued.keys, [3]);

      // Page 2 lays its lines out as they were queued.
      handle.goToPage!(2, animate: false);
      await tester.pump();
      expect(warmup.queued.keys, [0, 4]);
      expectLaidOutAsWarmed(tester, ahead);
      // The UI locale, as the lines set none, even for Japanese text.
      expect(ahead.first.locale?.languageCode, 'zh');

      // A new font size queues the pages of the new layout.
      settings.value = const NovelReaderSettings(fontSize: 24);
      await settle();
      final page = handle.currentPage!();
      expect(warmup.queued.keys, [page - 2, page + 2]);
      expect([
        for (final line in warmup.queued[page + 2]!) line.span.text,
      ], linesOf(page + 2));
    });
  }

  testWidgets('goToPage(animate:false) lands in a single frame', (
    tester,
  ) async {
    final handle = NovelReaderHandle();
    await tester.pumpWidget(
      localizedApp(
        body: NovelReader(novel: _novel('reader ' * 400), handle: handle),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final pageCount = handle.pageCount!.call();
    expect(pageCount, greaterThan(2));

    // jumpToPage applies the position synchronously — one frame after the
    // call the reader must already report the target page. An animated jump
    // would still be mid-flight at this point.
    handle.goToPage?.call(pageCount - 1, animate: false);
    await tester.pump();
    expect(handle.currentPage?.call(), pageCount - 1);

    // The animated path still works for short hops.
    handle.goToPage?.call(0);
    await tester.pumpAndSettle();
    expect(handle.currentPage?.call(), 0);
  });

  testWidgets('anchor notifications distinguish echoes from user turns', (
    tester,
  ) async {
    final causes = <NovelAnchorCause>[];
    final handle = NovelReaderHandle();
    final text = List.generate(
      80,
      (index) => 'paragraph $index body text body text',
    ).join('\n\n');

    Widget app(double fontSize) => MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: NovelReader(
          novel: _novel(text),
          settings: NovelReaderSettings(fontSize: fontSize),
          // A deep restore makes the first commit's programmatic jump
          // observable on PageView.onPageChanged.
          initialAnchor: const NovelAnchor(paragraphId: 'p60', offset: 0),
          handle: handle,
          onAnchorChanged: (anchor, cause) => causes.add(cause),
        ),
      ),
    );

    await tester.pumpWidget(app(17));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // First layout + restore jump: every notification is a layout echo.
    expect(causes, isNotEmpty);
    expect(
      causes.where((cause) => cause == NovelAnchorCause.userTurn),
      isEmpty,
    );

    // A tap turn is a user commit.
    causes.clear();
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    expect(causes, contains(NovelAnchorCause.userTurn));

    // A settings-driven relayout re-asserts position as an echo again.
    causes.clear();
    await tester.pumpWidget(app(20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(causes, isNotEmpty);
    expect(
      causes.where((cause) => cause == NovelAnchorCause.userTurn),
      isEmpty,
    );
  });

  testWidgets('layout budget overflow renders a retryable error state', (
    tester,
  ) async {
    final engine = _CountingLayoutEngine();
    await tester.pumpWidget(
      ProviderScope(
        child: localizedApp(
          body: NovelReader(
            novel: _novel('reader ' * 400),
            layoutEngine: engine,
            budget: const NovelLayoutBudget(maxTextUnits: 2),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The budget failure lands on the committed error state instead of
    // escaping as an unhandled async exception.
    expect(find.byType(FeedError), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(engine.calls, 1);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Retry forces another layout pass; the deterministic failure keeps
    // the error state visible.
    expect(engine.calls, 2);
    expect(find.byType(FeedError), findsOneWidget);
  });

  testWidgets('goToPage is a no-op while the layout error state is shown', (
    tester,
  ) async {
    final handle = NovelReaderHandle();
    await tester.pumpWidget(
      ProviderScope(
        child: localizedApp(
          body: NovelReader(
            novel: _novel('reader ' * 400),
            handle: handle,
            budget: const NovelLayoutBudget(maxTextUnits: 2),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(FeedError), findsOneWidget);
    // The PageView is unmounted in the error state — a jump landing on the
    // detached controller would assert in debug and throw in release.
    handle.goToPage?.call(0, animate: false);
    handle.goToPage?.call(0);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(FeedError), findsOneWidget);
  });
}

/// Records each document-layout invocation so tests can assert a retry
/// really re-enters the engine.
class _CountingLayoutEngine extends NovelLayoutEngine {
  var calls = 0;

  @override
  Future<NovelLayout> layoutDocumentCancellable({
    required NovelMarkupDocument document,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
    TextScaler textScaler = TextScaler.noScaling,
    Map<String, String> translations = const {},
    CancelToken? cancelToken,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) {
    calls += 1;
    return super.layoutDocumentCancellable(
      document: document,
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      textColor: textColor,
      brightness: brightness,
      textDirection: textDirection,
      textScaler: textScaler,
      translations: translations,
      cancelToken: cancelToken,
      budget: budget,
      onProgress: onProgress,
    );
  }
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

Map<String, dynamic> _novelJson(String content) => {
  'novel': {
    'id': 77,
    'title': 'A novel',
    'caption': 'caption',
    'restrict': 0,
    'x_restrict': 0,
    'image_urls': {'medium': 'https://i.pximg.net/cover.png'},
    'tags': [
      {'name': 'tag', 'translated_name': 'tag translated'},
    ],
    'text_length': content.length,
    'content': content,
    'user': {
      'id': 8,
      'name': 'author',
      'account': 'author',
      'profile_image_urls': {'medium': 'https://i.pximg.net/avatar.png'},
    },
    'series': {'id': 12, 'title': 'Series'},
    'visible': true,
  },
};

class _RecordingWarmup extends FeedTextWarmup {
  final queued = <int, List<WarmText>>{};

  @override
  void add(
    Iterable<WarmText> texts, {
    required int item,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    queued[item] = texts.toList();
  }

  @override
  void clear() => queued.clear();
}
