import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/widgets/feed/feed_states.dart';

import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/core/novel/reader_settings.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/novel/novel_layout.dart';
import 'package:pixiv_func/features/novel/novel_reader.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

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
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

        home: Scaffold(
          body: NovelReader(
            novel: _novel('reader ' * 400),
            handle: handle,
            onCenterTap: () => centerTaps += 1,
            onProgressChanged: (page, pageCount) => pages = pageCount,
          ),
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

  testWidgets('goToPage(animate:false) lands in a single frame', (
    tester,
  ) async {
    final handle = NovelReaderHandle();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: NovelReader(novel: _novel('reader ' * 400), handle: handle),
        ),
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
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
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

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Retry forces another layout pass; the deterministic failure keeps
    // the error state visible.
    expect(engine.calls, 2);
    expect(find.byType(FeedError), findsOneWidget);
  });

  testWidgets('handle exposes ordered chapter entries from the layout', (
    tester,
  ) async {
    final handle = NovelReaderHandle();
    const source =
        'intro paragraph\n[[chapter:第一章]]\nchapter one body\n'
        '[[chapter:第二章]]\nchapter two body';
    final markup = NovelContentMapper.parse(source);
    final novel = NovelEntity(
      id: 77,
      title: 'A novel',
      caption: '',
      user: const UserEntity(id: 8, name: 'author', account: 'author'),
      tags: const [],
      textLength: source.length,
      contentVersion: source,
      paragraphs: markup.paragraphs,
      markup: markup,
      contentAvailable: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(body: NovelReader(novel: novel, handle: handle)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final chapters = handle.chapters!.call();
    expect(chapters.map((entry) => entry.title), ['第一章', '第二章']);
    // Page indices are ordered and inside the laid-out range.
    expect(chapters.first.pageIndex, greaterThan(0));
    expect(chapters[0].pageIndex, lessThan(chapters[1].pageIndex));
    expect(chapters.last.pageIndex, lessThan(handle.pageCount!.call()));

    // Jumping to a chapter lands on its page.
    handle.goToPage?.call(chapters[1].pageIndex, animate: false);
    await tester.pump();
    expect(handle.currentPage?.call(), chapters[1].pageIndex);
  });

  testWidgets(
    'wide layouts cap the text column at fontSize*40 and keep edge taps',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final handle = NovelReaderHandle();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Scaffold(
            body: NovelReader(novel: _novel('reader ' * 400), handle: handle),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Default fontSize 17 → cap 17*40 + 2*24 = 728, fed into the layout
      // cache key rather than only clipping the render width.
      const cap = 17 * 40 + 2 * 24.0;
      expect(handle.layout!.call()!.key.viewport.width, cap);

      // The text column centers inside the 1200-wide page slot.
      final column = find.byWidgetPredicate(
        (widget) =>
            widget is ConstrainedBox && widget.constraints.maxWidth == cap,
      );
      expect(column, findsWidgets);
      expect(
        tester.getRect(column.first).left,
        closeTo((1200 - cap) / 2, 0.5),
      );

      // A tap in the right margin — outside the centered column — still
      // turns the page; the gesture zones span the full width.
      await tester.tapAt(const Offset(1190, 400));
      await tester.pumpAndSettle();
      expect(handle.currentPage?.call(), 1);
    },
  );

  testWidgets('narrow layouts keep the full viewport width', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final handle = NovelReaderHandle();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: NovelReader(novel: _novel('reader ' * 400), handle: handle),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 390 < 728 → the cap never engages on phones.
    expect(handle.layout!.call()!.key.viewport.width, 390);
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
