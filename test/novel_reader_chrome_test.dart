import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:parfait/features/novel/novel_page.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/app/widgets/feed/feed_states.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/prompt_host.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/novel_reader_harness.dart';
import 'helpers/waits.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';

Future<ProviderContainer> _apiContainer({
  SharedPreferencesAsyncPlatform? platform,
  bool withSeries = false,
  Future<http.Response> Function(int request)? seriesHandler,
  List<Uri>? seriesRequests,
  Completer<void>? detailGate,
  bool detailFails = false,
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
      if (request.url.path == '/webview/v2/novel') {
        final body = jsonEncode('chapter ' * 600);
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
    "marker": null
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

Finder _progressSuffix() => find.textContaining(RegExp(r'^ · \d+/\d+ · \d+%'));

Finder _progressHint() =>
    find.ancestor(of: _progressSuffix(), matching: find.byType(MergeSemantics));

/// Pumps until the async pagination lands on its real page count: the
/// controller boots at `1/1`, so a still-laying-out footer always shows
/// `· 1/1 ·`. Layout yields on zero-duration timers, which `pump` drains.
Future<void> _settleReader(WidgetTester tester) {
  final suffix = _progressSuffix();
  return pumpUntil(
    tester,
    () =>
        suffix.tryEvaluate() &&
        !tester.widget<Text>(suffix).data!.contains('· 1/1 ·'),
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
  int? atPixivPage,
}) async {
  await tester.pumpWidget(
    localizedApp(
      container: container,
      builder: promptHostBuilder,
      home: pushed
          ? const _Host()
          : NovelPage(novelId: 1, atPixivPage: atPixivPage),
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
  ProviderContainer container, {
  int? atPixivPage,
}) async {
  await _mountReader(tester, container, atPixivPage: atPixivPage);
  await _settleReader(tester);
}

Map<String, dynamic> _seriesNovel(int id, String title) => {
  ...novelJson(id, title: title),
  'content_order': '$id',
};

Map<String, Object> _seriesJson(
  List<Map<String, dynamic>> novels, {
  String? nextUrl,
}) => {
  'novels': novels,
  'novel_series_detail': {
    'id': 5,
    'title': 'series five',
    'watchlist_added': false,
  },
  'next_url': ?nextUrl,
};

http.Response _seriesResponse(
  List<Map<String, dynamic>> novels, {
  String? nextUrl,
}) => http.Response.bytes(
  utf8.encode(jsonEncode(_seriesJson(novels, nextUrl: nextUrl))),
  200,
  headers: {'content-type': 'application/json'},
);

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
    expect(_progressHint(), findsOneWidget);
    expect(
      find.descendant(of: _progressHint(), matching: find.text('novel 1')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // Center tap reveals the chrome; the title appears exactly once.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(barTitle(), findsOneWidget);
    expect(_progressHint(), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(AppIcons.info), findsOneWidget);
    expect(find.byIcon(AppIcons.share), findsOneWidget);
    expect(find.byIcon(AppIcons.textDecrease), findsOneWidget);
    // Adjacent navigation from the webview payload rides the bottom bar.
    expect(find.byIcon(UiIcons.chevronLeft), findsOneWidget);
    expect(find.byIcon(UiIcons.chevronRight), findsOneWidget);

    // System back closes the chrome instead of popping the page.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    expect(barTitle(), findsNothing);
    expect(_progressHint(), findsOneWidget);

    // The dismissed bars stay mounted offstage, out of the semantics tree;
    // the next reveal reuses their laid-out text.
    final semantics = tester.ensureSemantics();
    final paragraph = tester.renderObject(barTitle(skipOffstage: false));
    // The page's title block is the one title node while the bar is gone
    // (the passive hint merges `' · page/total'` onto a second line).
    final titleNodes = find.semantics.byLabel(RegExp(r'^novel 1(\n[^ ]|$)'));
    expect(titleNodes, findsOne);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(tester.renderObject(barTitle()), same(paragraph));
    expect(titleNodes, findsExactly(2));
    semantics.dispose();
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
    expect(find.byIcon(AppIcons.watchlistAdd), findsOneWidget);
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
            find.widgetWithIcon(IconButton, UiIcons.chevronLeft),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, UiIcons.chevronRight),
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

  testWidgets(
    'reader palette isolates stage theme from opposite app brightness',
    (tester) async {
      double contrast(Color a, Color b) {
        final l1 = a.computeLuminance();
        final l2 = b.computeLuminance();
        final hi = l1 > l2 ? l1 : l2;
        final lo = l1 > l2 ? l2 : l1;
        return (hi + 0.05) / (lo + 0.05);
      }

      for (final (appBrightness, readerTheme, expectedBrightness) in [
        (Brightness.dark, NovelReaderTheme.paper, Brightness.light),
        (Brightness.light, NovelReaderTheme.night, Brightness.dark),
      ]) {
        final container = await _apiContainer(
          withSeries: true,
          platform: novelReaderSettingsPrefs(
            NovelReaderSettings(theme: readerTheme),
          ),
          seriesHandler: (_) async =>
              _seriesResponse([_seriesNovel(1, 'one'), _seriesNovel(2, 'two')]),
        );
        await tester.pumpWidget(
          localizedApp(
            container: container,
            theme: replicaTheme(appBrightness),
            home: const NovelPage(novelId: 1),
          ),
        );
        await tester.pump();
        await _settleReader(tester);
        await tester.tapAt(const Offset(400, 300));
        await tester.pumpAndSettle();

        final stageTheme = Theme.of(
          tester.element(find.byKey(const Key('novel-series-bar-title'))),
        );
        final bg = novelReaderPalette(readerTheme).background!;
        expect(stageTheme.brightness, expectedBrightness);
        expect(
          contrast(stageTheme.colorScheme.onSurface, bg),
          greaterThan(4.5),
        );
        expect(contrast(stageTheme.colorScheme.primary, bg), greaterThan(3.0));
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('series pagination resolves chapters across next_url and keeps '
      'fallback prev/next on series fetch failure', (tester) async {
    final requests = <Uri>[];
    final container = await _apiContainer(
      withSeries: true,
      seriesRequests: requests,
      seriesHandler: (attempt) async => attempt == 1
          ? _seriesResponse(
              [_seriesNovel(9, 'prev')],
              nextUrl:
                  'https://app-api.pixiv.net/v2/novel/series?series_id=5&last_order=1',
            )
          : _seriesResponse([
              _seriesNovel(1, 'current'),
              _seriesNovel(2, 'next'),
            ]),
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(requests.length, 2);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, UiIcons.chevronLeft),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, UiIcons.chevronRight),
          )
          .onPressed,
      isNotNull,
    );
    final cursor = await container
        .read(watchlistReadCursorProvider)
        .read('account', const WatchlistKey(WatchlistType.novel, 5));
    expect(cursor, 1);

    // When /v2/novel/series fails outright, adjacent IDs from webview payload
    // still keep prev/next buttons enabled alongside Retry.
    await tester.pumpWidget(const SizedBox());
    final failContainer = await _apiContainer(
      withSeries: true,
      seriesHandler: (_) async => http.Response('err', 503),
    );
    await _openReader(tester, failContainer);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, UiIcons.chevronLeft),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, UiIcons.chevronRight),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('reader keyboard handler ignores Alt/Ctrl/Meta modifier chords', (
    tester,
  ) async {
    final container = await _apiContainer(
      platform: novelReaderSettingsPrefs(novelPageModeSettings),
    );
    await _openReader(tester, container);
    expect(tester.widget<Text>(_progressSuffix()).data, contains('· 1/'));

    // Alt+ArrowRight must pass through without flipping the page.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    }
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_progressSuffix()).data, contains('· 1/'));

    // Unmodified ArrowRight still advances to page 2.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(_progressSuffix()).data, contains('· 2/'));
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
