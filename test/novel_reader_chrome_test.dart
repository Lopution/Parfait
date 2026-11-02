import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/app/system_ui.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_page.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/prompt_host.dart';

import 'helpers/fake_account.dart';
import 'helpers/prompt_host.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/waits.dart';

Future<ProviderContainer> _apiContainer({
  SharedPreferencesAsyncPlatform? platform,
  bool withSeries = false,
  Future<http.Response> Function(int request)? seriesHandler,
  List<Uri>? seriesRequests,
  Completer<void>? detailGate,
  bool detailFails = false,
  String? text,
  Map<String, Object>? marker,
  List<http.Request>? markerWrites,
  bool Function()? markerWriteFails,
}) async {
  if (platform != null) installPreferencesForTest(platform);
  final container = await signedInApiContainer(
    MockClient((request) async {
      if (request.url.path == '/v2/novel/detail') {
        await detailGate?.future;
        // Account B ('200') has no detail.
        final b = request.headers['authorization']!.contains('access-200');
        if (detailFails || b) return http.Response('{}', 503);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'novel': {
                'id': 1,
                'title': 'novel 1',
                'caption': 'line one<br />line two<br>line three',
                'restrict': 0,
                'x_restrict': 0,
                'is_bookmarked': false,
                'text_length': 4000,
                'total_view': 1234,
                'total_bookmarks': 56,
                'create_date': '2026-10-01T12:34:00+09:00',
                'visible': true,
                'user': {
                  'id': 10,
                  'name': 'user 10',
                  'account': 'user_10',
                  'profile_image_urls': <String, String>{},
                },
                'tags': [
                  {'name': 'tag1', 'translated_name': 't1'},
                ],
                'image_urls': <String, String>{},
                if (withSeries) 'series': {'id': 5, 'title': 'series five'},
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.startsWith('/v1/novel/marker/')) {
        markerWrites?.add(request);
        if (markerWriteFails?.call() ?? false) {
          return http.Response('{"error": {"message": "nope"}}', 400);
        }
        return http.Response('{}', 200);
      }
      if (request.url.path == '/webview/v2/novel') {
        final body = jsonEncode(text ?? 'chapter ' * 600);
        return http.Response.bytes(
          utf8.encode('''
<script>
Object.defineProperty(window, 'pixiv', {value: {
  "context": {"csrfToken": "x"},
  "novel": {
    "id": "1",
    "title": "novel 1",
    "text": $body,
    "userId": "10",
    "coverUrl": "https://i.pximg.net/c/1.jpg",
    "tags": ["tag1"],
    "caption": "caption 1",
    "seriesNavigation": {"prevNovel": {"id": 9}, "nextNovel": {"id": 11}},
    "marker": ${jsonEncode(marker)}
  },
}, configurable: true, writable: true});
</script>
'''),
          200,
          headers: {'content-type': 'text/html'},
        );
      }
      if (request.url.path == '/v2/novel/series') {
        seriesRequests?.add(request.url);
        final handler = seriesHandler;
        if (handler != null) return handler(seriesRequests?.length ?? 1);
      }
      return http.Response('not found', 404);
    }),
    account: const Account(id: 'account', userId: 10, name: 'tester'),
    others: const [Account(id: '200', userId: 200, name: 'b')],
  );
  return container;
}

/// Pumps until the async pagination lands on its real page count: the
/// controller boots at `1/1`, so a still-laying-out footer always shows
/// `· 1/1 ·`. Layout yields on zero-duration timers, which `pump` drains.
Future<void> _settleReader(WidgetTester tester) {
  final hint = find.textContaining('novel 1 ·');
  return pumpUntil(
    tester,
    () =>
        hint.tryEvaluate() &&
        !tester.widget<Text>(hint).data!.contains('· 1/1 ·'),
    step: const Duration(milliseconds: 50),
    frames: 80,
  );
}

/// Mounts [NovelPage] (pushed over a host page when [pushed]) and lets the
/// detail and webview fetches and the first layout pass land.
Future<void> _mountReader(
  WidgetTester tester,
  ProviderContainer container, {
  bool pushed = false,
}) async {
  await tester.pumpWidget(
    localizedApp(
      container: container,
      builder: promptHostBuilder,
      home: pushed ? const _Host() : const NovelPage(novelId: 1),
    ),
  );
  if (pushed) {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// [_mountReader], then waits out the async pagination. Chrome still starts
/// hidden; reveal it with a center tap.
Future<void> _openReader(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await _mountReader(tester, container);
  await _settleReader(tester);
}

Map<String, Object> _seriesNovel(int id, String title) => {
  'id': id,
  'title': title,
  'visible': true,
  'content_order': '$id',
};

Map<String, Object> _seriesJson(List<Map<String, Object>> novels) => {
  'novels': novels,
  'novel_series_detail': {
    'id': 5,
    'title': 'series five',
    'watchlist_added': false,
  },
};

http.Response _seriesResponse(List<Map<String, Object>> novels) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(_seriesJson(novels))),
      200,
      headers: {'content-type': 'application/json'},
    );

/// Three Pixiv pages, each opening with a line that names it.
final _threePages = [
  for (var page = 1; page <= 3; page++)
    [
      'PAGE$page begins',
      for (var line = 0; line < 40; line++) 'page $page line $line text',
    ].join('\n'),
].join('\n[newpage]\n');

void main() {
  testWidgets('immersive reader: chrome toggles, back closes chrome first', (
    tester,
  ) async {
    final container = await _apiContainer();
    await _mountReader(tester, container);

    // The page's title block names the novel too; these look at the bar.
    Finder barTitle({bool skipOffstage = true}) => find.descendant(
      of: find.byType(NavigationToolbar, skipOffstage: skipOffstage),
      matching: find.text('novel 1', skipOffstage: skipOffstage),
    );

    expect(find.byType(ListView), findsOneWidget);
    // Chrome is hidden by default, so the bar's title is not on screen
    // yet. The passive footer is the only title-bearing readout in the
    // hidden state.
    expect(barTitle(), findsNothing);
    expect(find.textContaining('novel 1 ·'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // Center tap reveals the chrome; the title appears exactly once.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(barTitle(), findsOneWidget);
    expect(find.textContaining('novel 1 ·'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.text_decrease_outlined), findsOneWidget);
    // Adjacent navigation from the webview payload rides the bottom bar.
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    // System back closes the chrome instead of popping the page.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    expect(barTitle(), findsNothing);
    expect(find.textContaining('novel 1 ·'), findsOneWidget);

    // The dismissed bars stay mounted offstage, out of the semantics tree;
    // the next reveal reuses their laid-out text.
    final semantics = tester.ensureSemantics();
    final paragraph = tester.renderObject(barTitle(skipOffstage: false));
    // The page's title block is the one title node while the bar is gone.
    final titleNodes = find.semantics.byLabel(RegExp(r'^novel 1(\n|$)'));
    expect(titleNodes, findsOne);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(tester.renderObject(barTitle()), same(paragraph));
    expect(titleNodes, findsExactly(2));
    semantics.dispose();
  });

  testWidgets('the progress hint never overlaps the sliding bottom bar', (
    tester,
  ) async {
    // R4: the hint waits for the bar's `dismissed` edge in both
    // directions — on no frame may a finder see both at once.
    final container = await _apiContainer();
    await _mountReader(tester, container);

    bool hintShown() => find.textContaining('novel 1 ·').evaluate().isNotEmpty;
    bool barShown() =>
        find.byIcon(Icons.text_decrease_outlined).evaluate().isNotEmpty;
    void expectNotBoth(String direction, int frame) {
      expect(
        hintShown() && barShown(),
        isFalse,
        reason: 'frame $frame of the $direction slide shows both',
      );
    }

    // Starts hidden: hint on, bar off.
    expect(hintShown(), isTrue);
    expect(barShown(), isFalse);

    // Show direction: the hint leaves on the slide-in's first frame.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      expectNotBoth('show', i);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(barShown(), isTrue);
    expect(hintShown(), isFalse);

    // Hide direction: the bar owns the strip until it is dismissed; the
    // hint returns only on the frame the bar leaves the tree.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      expectNotBoth('hide', i);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(barShown(), isFalse);
    expect(hintShown(), isTrue);
  });

  testWidgets('system back pops the page when the chrome is hidden', (
    tester,
  ) async {
    // §5.4 ordering leg three: canPop = !chromeVisible, so with the bars
    // already hidden a system back must leave the page outright (the
    // chrome-first interception only applies while chrome is visible).
    final container = await _apiContainer();
    await _mountReader(tester, container, pushed: true);

    expect(find.byType(ListView), findsOneWidget);
    // Chrome starts hidden — the back affordance is not on screen.
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(NovelPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('explicit back leaves the page even while chrome is visible', (
    tester,
  ) async {
    final container = await _apiContainer();
    await _mountReader(tester, container, pushed: true);

    expect(find.byType(ListView), findsOneWidget);

    // Reveal the chrome, then use the explicit back control: it must leave
    // the page instead of only hiding the bars. The PopScope's chrome-first
    // interception covers the system back gesture; an imperative pop()
    // bypasses it (flutter/flutter#163052).
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.byType(NovelPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a pending detail shows the page skeleton, not an empty state', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final container = await _apiContainer(detailGate: gate);
    await tester.pumpWidget(
      localizedApp(container: container, home: NovelPage(novelId: 1)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(NovelPageSkeleton), findsOneWidget);
    expect(find.byType(FeedLoading), findsNothing);
    expect(find.byType(FeedEmpty), findsNothing);
    expect(find.bySemanticsLabel('正在加载小说'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(NovelPageSkeleton), findsNothing);
  });

  testWidgets('a detail landing after a switch stays out of B\'s store', (
    tester,
  ) async {
    final gate = Completer<void>();
    final container = await _apiContainer(detailGate: gate);
    await tester.pumpWidget(
      localizedApp(container: container, home: NovelPage(novelId: 1)),
    );
    await tester.pump();
    await container.read(accountStoreProvider.notifier).switchAccount('200');
    container.read(novelStoreProvider);
    gate.complete();
    await tester.pumpAndSettle();
    expect(container.read(novelStoreProvider)[1], isNull);
  });

  testWidgets('a failed detail reaches the error state at once', (
    tester,
  ) async {
    final container = await _apiContainer(detailFails: true);
    await tester.pumpWidget(
      localizedApp(container: container, home: NovelPage(novelId: 1)),
    );
    // No retry backoff in between: the first failure is the error state.
    // (Riverpod's default retry would first wait 200ms, then longer.)
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(FeedError), findsOneWidget);
    expect(find.byType(NovelPageSkeleton), findsNothing);
  });

  testWidgets('a failed series fetch shows localized text and retries', (
    tester,
  ) async {
    // R5: the failure strip is the localized fallback plus a retry —
    // never the raw exception — and retry issues exactly one more fetch.
    final requests = <Uri>[];
    var attempts = 0;
    final container = await _apiContainer(
      withSeries: true,
      seriesRequests: requests,
      seriesHandler: (_) async {
        attempts += 1;
        return attempts == 1
            ? http.Response('server exploded', 500)
            : _seriesResponse([_seriesNovel(1, 'one'), _seriesNovel(2, 'two')]);
      },
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    final strip = find.textContaining('系列信息暂不可用');
    expect(strip, findsOneWidget);
    final text = tester.widget<Text>(strip).data!;
    for (final raw in ['500', 'Exception', 'ApiError', 'server exploded']) {
      expect(
        text.contains(raw),
        isFalse,
        reason: 'raw error detail leaked into the strip',
      );
    }

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests.length, 2, reason: 'retry must issue exactly one fetch');
    expect(find.text('series five'), findsOneWidget);
    expect(find.byIcon(Icons.library_add_outlined), findsOneWidget);
  });

  testWidgets('a series missing the current entry dead-ends navigation', (
    tester,
  ) async {
    // R5: the opened novel is not in the series — title and watchlist
    // still render but prev/next stay disabled and no cursor is written.
    final container = await _apiContainer(
      withSeries: true,
      seriesHandler: (_) async =>
          _seriesResponse([_seriesNovel(2, 'two'), _seriesNovel(3, 'three')]),
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(find.text('series five'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_left),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed,
      isNull,
    );

    final cursor = await container
        .read(watchlistReadCursorProvider)
        .read('account', const WatchlistKey(WatchlistType.novel, 5));
    expect(
      cursor,
      isNull,
      reason: 'a missing entry must not move the seen cursor',
    );
  });

  testWidgets('the series fetch happens once across chrome toggles', (
    tester,
  ) async {
    // R5: the stage keeps the provider alive — the bar unmounts with the
    // chrome but the request must not repeat on every reveal.
    final requests = <Uri>[];
    final container = await _apiContainer(
      withSeries: true,
      seriesRequests: requests,
      seriesHandler: (_) async =>
          _seriesResponse([_seriesNovel(1, 'one'), _seriesNovel(2, 'two')]),
    );
    await _openReader(tester, container);

    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('novel 1 ·'), findsOneWidget);
    expect(
      requests.length,
      1,
      reason: 'hiding and revealing the chrome must not refetch',
    );
  });

  testWidgets('a seen cursor that fails to save leaves the page working', (
    tester,
  ) async {
    final preferences = IntWriteFailingPreferences();
    final container = await _apiContainer(
      withSeries: true,
      platform: preferences,
      seriesHandler: (_) async =>
          _seriesResponse([_seriesNovel(1, 'one'), _seriesNovel(2, 'two')]),
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('series five'), findsOneWidget);
    expect(preferences.intWrites, [1], reason: 'the open novel');
  });

  testWidgets('system bars hide with the chrome and return on pop', (
    tester,
  ) async {
    // R1: open hidden → immersiveSticky; reveal → edgeToEdge; hide →
    // immersiveSticky; pop → edgeToEdge on the first frame of the pop,
    // before dispose ever runs.
    final modes = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        modes.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final container = await _apiContainer();
    await _mountReader(tester, container, pushed: true);

    expect(
      modes.last,
      'SystemUiMode.immersiveSticky',
      reason: 'the reader opens with chrome hidden → immersive',
    );

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(
      modes.last,
      'SystemUiMode.edgeToEdge',
      reason: 'revealing the chrome brings the bars back',
    );
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(
      modes.last,
      'SystemUiMode.immersiveSticky',
      reason: 'hiding the chrome re-immerses',
    );
    await tester.pumpAndSettle();

    // Chrome is hidden, so this back pops the page outright; the ambient
    // mode must already be restored on the first frame after the pop is
    // handled — dispose fires only when the pop animation ends.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      modes.last,
      'SystemUiMode.edgeToEdge',
      reason: 'edgeToEdge is requested as the pop starts, not at dispose',
    );
    await tester.pumpAndSettle();
    expect(find.byType(NovelPage), findsNothing);
  });

  testWidgets('explicit back restores edge-to-edge during the pop', (
    tester,
  ) async {
    // R1 second leg: an imperative pop bypasses the chrome-first
    // interception but still reports through onPopInvokedWithResult.
    final modes = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        modes.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final container = await _apiContainer();
    await _mountReader(tester, container, pushed: true);

    // Reveal the chrome (edgeToEdge), then leave through the explicit
    // back control: the mode must already be ambient on the first frame
    // of the pop animation.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(modes.last, 'SystemUiMode.edgeToEdge');

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(
      modes.last,
      'SystemUiMode.edgeToEdge',
      reason: 'an imperative pop also restores the ambient mode early',
    );
    await tester.pumpAndSettle();
    expect(find.byType(NovelPage), findsNothing);
  });

  testWidgets('the progress hint never overlaps the last body line', (
    tester,
  ) async {
    // Gesture-nav bottom inset 48 — the case where the hint band used to
    // ride on top of the last text line.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.reset);

    for (final (pageTurn, scale) in [
      for (final pageTurn in NovelPageTurn.values)
        for (final scale in [1.0, 2.0]) (pageTurn, scale),
    ]) {
      final container = await _apiContainer(
        platform: memoryPreferences({
          'parfait.novel.reader_settings.v1': jsonEncode(
            NovelReaderSettings(pageTurn: pageTurn).toJson(),
          ),
        }),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const NovelPage(novelId: 1),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await _settleReader(tester);

      final hint = tester.getRect(find.textContaining('novel 1 ·'));
      if (pageTurn == NovelPageTurn.scroll) {
        // The column shows its lines only above the bottom margin; the
        // hint lives in that margin.
        final text = tester.getRect(find.byType(NovelReader));
        expect(
          hint.top,
          greaterThanOrEqualTo(
            text.bottom - const NovelLayoutStyle().verticalPadding,
          ),
          reason: 'scale $scale: hint $hint must sit below the text area',
        );
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        continue;
      }
      var lastLineBottom = 0.0;
      Rect? lastLine;
      for (final line in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(NovelReader),
          matching: find.byType(Text),
        ),
      )) {
        final rect = tester.getRect(find.byWidget(line));
        if (rect.bottom > lastLineBottom) {
          lastLineBottom = rect.bottom;
          lastLine = rect;
        }
      }
      expect(
        lastLine,
        isNotNull,
        reason: 'scale $scale: the laid-out page must have text lines',
      );
      expect(
        hint.overlaps(lastLine!),
        isFalse,
        reason:
            'scale $scale: hint $hint must not cover the last body line '
            '$lastLine',
      );
      // Sanity: the hint itself still sits inside the bottom inset band
      // it is supposed to live in.
      expect(hint.bottom, lessThanOrEqualTo(600));
      // The page goes first, as in the app: its last history commit needs
      // the container's database.
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    }
  });

  testWidgets('leaving the reader restores the root bar style', (tester) async {
    // R2: the stage's FuncSystemBars is a scoped override — unmounting the
    // route returns the bars to the app-level default without a reset.
    final container = await _apiContainer(
      platform: memoryPreferences({
        'parfait.novel.reader_settings.v1': jsonEncode(
          const NovelReaderSettings(theme: NovelReaderTheme.night).toJson(),
        ),
      }),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          theme: replicaTheme(Brightness.light),
          // The same root default app.dart's builder installs.
          builder: (context, routeChild) => FuncSystemBars(
            background: Theme.of(context).brightness,
            child: routeChild ?? const SizedBox.shrink(),
          ),
          home: const _Host(),
        ),
      ),
    );
    // Two pumps: mount, then RenderView publishes latestStyle.
    await tester.pump();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.dark,
      reason: 'the light root theme starts with dark icons',
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.light,
      reason: 'the night palette owns both bars while mounted',
    );
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.byType(NovelPage), findsNothing);
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.dark,
      reason: 'unmounting the reader restores the root style',
    );
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.dark,
    );
  });
  testWidgets('the account\'s bookmark: opened at without a place of your '
      'own; marked, moved and removed from the progress sheet', (tester) async {
    final writes = <http.Request>[];
    var failWrites = false;
    final container = await _apiContainer(
      text: _threePages,
      marker: const {'page': 3},
      markerWrites: writes,
      markerWriteFails: () => failWrites,
    );
    final places = container.read(novelProgressStoreProvider);
    Finder line(String text) => find.textContaining(text, findRichText: true);
    await _openReader(tester, container);

    // No place of this account's own: the reader opens at page 3's first
    // line, and opening writes none.
    expect(tester.getTopLeft(line('PAGE3 begins')).dy, lessThan(100));
    expect(await places.read('account', 1), isNull);

    Future<void> openSheet() async {
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('阅读进度'));
      await tester.pumpAndSettle();
    }

    Map<String, String> fields(http.Request request) =>
        Uri.splitQueryString(request.body);

    await openSheet();
    expect(find.text('书签'), findsOneWidget);
    expect(find.text('移到此页'), findsNothing);

    await tester.tap(find.byTooltip('删除书签'));
    await tester.pumpAndSettle();
    expect(writes.single.url.path, '/v1/novel/marker/delete');
    expect(fields(writes.single), {'novel_id': '1'});
    expect(container.read(novelStoreProvider)[1]!.markerPage, isNull);

    // A failed write says so and leaves the sheet as the account has it.
    failWrites = true;
    await tester.tap(find.text('在此页加书签'));
    await tester.pumpAndSettle();
    expect(find.textContaining('书签操作失败'), findsOneWidget);
    expect(find.text('在此页加书签'), findsOneWidget);
    expect(container.read(novelStoreProvider)[1]!.markerPage, isNull);
    PromptHost.of(tester.element(find.byType(NovelReader))).hideCurrent();
    await tester.pumpAndSettle();

    failWrites = false;
    await tester.tap(find.text('在此页加书签'));
    await tester.pumpAndSettle();
    expect(writes.last.url.path, '/v1/novel/marker/add');
    expect(writes, hasLength(3));
    expect(fields(writes.last), {'novel_id': '1', 'page': '3'});
    expect(find.text('书签'), findsOneWidget);

    // Back on page 1 by the reader's own scroll: the marker can move here.
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();
    await openSheet();
    await tester.tap(find.text('移到此页'));
    await tester.pumpAndSettle();
    expect(fields(writes.last), {'novel_id': '1', 'page': '1'});
    expect(find.text('移到此页'), findsNothing);

    // A place of the account's own wins over the bookmark on the next open.
    await tester.pumpWidget(const SizedBox());
    await _openReader(tester, container);
    expect(line('PAGE1 begins'), findsOneWidget);
    expect(line('PAGE3 begins'), findsNothing);
  });

  testWidgets('a one-page novel without a bookmark offers none', (
    tester,
  ) async {
    final container = await _apiContainer();
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('阅读进度'));
    await tester.pumpAndSettle();
    expect(find.text('在此页加书签'), findsNothing);
  });

  testWidgets('the info sheet names the series, length, counts and date', (
    tester,
  ) async {
    for (final withSeries in [true, false]) {
      final container = await _apiContainer(withSeries: withSeries);
      await tester.pumpWidget(const SizedBox());
      await _openReader(tester, container);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();

      expect(find.text('4000 字'), findsOneWidget);
      expect(find.text('1234'), findsOneWidget);
      expect(find.text('56'), findsOneWidget);
      expect(find.textContaining('2026'), findsOneWidget);
      // The series is named, not linked: the reader's bar steps through it.
      final series = find.descendant(
        of: find.byKey(const Key('novel-info-facts')),
        matching: find.text('series five'),
      );
      expect(series, withSeries ? findsOneWidget : findsNothing);

      // One node: the series, the length, then the stats sentence.
      final semantics = tester.ensureSemantics();
      final label = tester
          .getSemantics(find.byKey(const Key('novel-info-facts')))
          .label;
      expect(
        label,
        stringContainsInOrder([
          if (withSeries) ...['系列', 'series five'],
          '4000 字',
          '1234 次浏览，56 次收藏，发布于 2026',
        ]),
      );
      semantics.dispose();
    }
  });
}

/// Host page that pushes [NovelPage], so an explicit back has a route to
/// land on.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const NovelPage(novelId: 1),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}
