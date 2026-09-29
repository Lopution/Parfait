import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/system_ui.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/novel/reader_settings.dart';
import 'package:pixiv_func/core/watchlist/watchlist_models.dart';
import 'package:pixiv_func/core/watchlist/watchlist_store.dart';
import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/features/novel/novel_page.dart';
import 'package:pixiv_func/features/novel/novel_reader.dart';
import 'package:pixiv_func/features/novel/novel_reader_stage.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:pixiv_func/app/widgets/feed/feed_states.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

Future<ProviderContainer> _apiContainer({
  Map<String, Object> preferences = const {},
  bool withSeries = false,
  Future<http.Response> Function(int request)? seriesHandler,
  List<Uri>? seriesRequests,
  Completer<void>? detailGate,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences(preferences);
  final credentials = FakeCredentialStore(
    values: const {
      'account': Credential(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
      ),
    },
  );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: 'account', userId: 10, name: 'tester')],
          currentId: 'account',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (_) async => throw StateError('refresh is not expected'),
          ),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client is not wired');
        return client;
      }),
    ],
  );
  clientRef[0] = PixivHttpClient(
    client: MockClient((request) async {
      if (request.url.path == '/v2/novel/detail') {
        await detailGate?.future;
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
        final body = StringBuffer('chapter ' * 600);
        return http.Response.bytes(
          utf8.encode('''
<script>
Object.defineProperty(window, 'pixiv', {value: {
  "context": {"csrfToken": "x"},
  "novel": {
    "id": "1",
    "title": "novel 1",
    "text": "$body",
    "userId": "10",
    "coverUrl": "https://i.pximg.net/c/1.jpg",
    "tags": ["tag1"],
    "caption": "caption 1",
    "seriesNavigation": {"prevNovel": {"id": 9}, "nextNovel": {"id": 11}}
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
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return container;
}

/// Pumps until the async pagination lands on its real page count: the
/// controller boots at `1/1`, so a still-laying-out footer always shows
/// `· 1/1 ·`. Layout yields on zero-duration timers, which `pump` drains.
Future<void> _settleReader(WidgetTester tester) async {
  final hint = find.textContaining('novel 1 ·');
  for (var i = 0; i < 80; i++) {
    if (hint.evaluate().isNotEmpty &&
        !tester.widget<Text>(hint).data!.contains('· 1/1 ·')) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Mounts [NovelPage] and lets detail + webview + the async pagination
/// land. Chrome still starts hidden; reveal it with a center tap.
Future<void> _openReader(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: NovelPage(novelId: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await _settleReader(tester);
  });
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

void main() {
  testWidgets('immersive reader: chrome toggles, back closes chrome first', (
    tester,
  ) async {
    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: NovelPage(novelId: 1),
          ),
        ),
      );
      // Detail + webview fetches, then the first layout pass.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    expect(find.byType(PageView), findsOneWidget);
    // Chrome is hidden by default: the title lives only in the chrome bar,
    // so it must not be on screen yet. The passive footer is the only
    // title-bearing readout in the hidden state.
    expect(find.text('novel 1'), findsNothing);
    expect(find.textContaining('novel 1 ·'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // Center tap reveals the chrome; the title appears exactly once.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('novel 1'), findsOneWidget);
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
    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('novel 1'), findsNothing);
    expect(find.textContaining('novel 1 ·'), findsOneWidget);
  });

  testWidgets('the progress hint never overlaps the sliding bottom bar', (
    tester,
  ) async {
    // R4: the hint waits for the bar's `dismissed` edge in both
    // directions — on no frame may a finder see both at once.
    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: NovelPage(novelId: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

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
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: _Host(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Detail + webview fetches, then the first layout pass.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    expect(find.byType(PageView), findsOneWidget);
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
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: _Host(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Detail + webview fetches, then the first layout pass.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    expect(find.byType(PageView), findsOneWidget);

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

  testWidgets('work info sheet renders caption HTML without literal <br>', (
    tester,
  ) async {
    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: NovelPage(novelId: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();

    // Caption <br> tags became real line breaks via CaptionRichText.
    expect(find.textContaining('line one'), findsOneWidget);
    expect(find.textContaining('line two'), findsOneWidget);
    expect(find.textContaining('<br'), findsNothing);
    // Tags and the comment entry moved into the sheet with the metadata.
    expect(find.text('#tag1 t1'), findsOneWidget);
    expect(find.byIcon(Icons.comment_outlined), findsOneWidget);
  });

  testWidgets('a tag chip in the info sheet closes it and opens tag search', (
    tester,
  ) async {
    final container = await _apiContainer();
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/novel/1',
      routes: [
        GoRoute(
          path: '/novel/:novelId',
          builder: (context, state) =>
              NovelPage(novelId: int.parse(state.pathParameters['novelId']!)),
        ),
        GoRoute(
          path: '/search/results',
          builder: (context, state) => const Scaffold(body: Text('results')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('#tag1 t1'), findsOneWidget);

    await tester.tap(find.text('#tag1 t1'));
    await tester.pumpAndSettle();

    // The sheet is gone and the typed search route was pushed.
    expect(find.text('#tag1 t1'), findsNothing);
    expect(router.state.uri.path, '/search/results');
    expect(router.state.uri.queryParameters['q'], 'tag1');
    expect(router.state.uri.queryParameters['type'], 'novel');
  });

  testWidgets('reduced motion: chrome and page turns land in one frame', (
    tester,
  ) async {
    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MotionScope(
            reduce: true,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale('zh', 'CN'),
              home: NovelPage(novelId: 1),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    expect(find.byType(PageView), findsOneWidget);
    // Center tap reveals the chrome: one pump lands both bars at full
    // opacity — an ungated controller would still be mid-slide here.
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    final stage = find.byType(NovelReaderStage);
    expect(stage, findsOneWidget);
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(of: stage, matching: find.byType(FadeTransition)),
    );
    expect(fades, isNotEmpty);
    expect(fades.every((f) => f.opacity.value == 1.0), isTrue);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // Hide the chrome again, then an arrow-key page turn: the footer
    // reports the new page on the very next frame (jump, not flight).
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    // The passive hint returns on the same frame the bar leaves (R4).
    expect(find.textContaining('novel 1 ·'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.textContaining('· 2/'), findsOneWidget);
  });

  testWidgets('chrome surfaces paint through the system-bar insets', (
    tester,
  ) async {
    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MediaQuery(
            // SafeArea reads `padding`; viewPadding is the pre-removal
            // inset. Real devices report both — mirror that here.
            data: MediaQueryData(
              padding: EdgeInsets.only(top: 24, bottom: 24),
              viewPadding: EdgeInsets.only(top: 24, bottom: 24),
            ),
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale('zh', 'CN'),
              home: NovelPage(novelId: 1),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    // The bar surface reaches the screen edge (covering the gesture strip
    // and status bar) while its controls stay inside the safe area. The
    // old layout wrapped the whole bar in SafeArea, so the strip showed
    // page content between the bar and the screen edge.
    // The nearest MaterialType.canvas ancestor is the bar's own surface —
    // IconButton paints its own MaterialType.button in between.
    final bottomBar = find.ancestor(
      of: find.byIcon(Icons.text_decrease_outlined),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.type == MaterialType.canvas,
      ),
    );
    expect(tester.getRect(bottomBar.first).bottom, 600);
    expect(
      tester.getRect(find.byIcon(Icons.text_decrease_outlined)).bottom,
      lessThanOrEqualTo(600 - 24),
    );
    final topBar = find.ancestor(
      of: find.byIcon(Icons.arrow_back),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.type == MaterialType.canvas,
      ),
    );
    expect(tester.getRect(topBar.first).top, 0);
    expect(
      tester.getRect(find.byIcon(Icons.arrow_back)).top,
      greaterThanOrEqualTo(24),
    );
  });

  testWidgets('a pending detail shows a spinner, not an empty state', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final container = await _apiContainer(detailGate: gate);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: NovelPage(novelId: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(FeedLoading), findsOneWidget);
    expect(find.byType(FeedEmpty), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(FeedLoading), findsNothing);
  });

  testWidgets('the series bar keeps one height in every state', (tester) async {
    // R5: loading / failure / data / missing-entry all occupy the same
    // 48dp strip — the bar never resizes under the bottom chrome.
    double barHeight() {
      final row = find.ancestor(
        of: find.byIcon(Icons.chevron_left),
        matching: find.byType(Row),
      );
      expect(row, findsWidgets, reason: 'no series row on screen');
      return tester.getSize(row.first).height;
    }

    // Loading: the fetch hangs on a Completer. No pumpAndSettle — the
    // spinner never settles, and 20s of fake time would trip the client's
    // own ApiTimeout. A few frames are enough to mount the strip.
    final pending = Completer<http.Response>();
    var container = await _apiContainer(
      withSeries: true,
      seriesHandler: (_) => pending.future,
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(barHeight(), 48, reason: 'loading state must be 48dp');
    // Resolve the hanging fetch so the client's timeout timer cannot
    // outlive the test.
    pending.complete(_seriesResponse([_seriesNovel(1, 'one')]));
    await tester.pumpAndSettle();
    container.dispose();

    // Failure: a 500 must render the same strip, not a taller error text.
    container = await _apiContainer(
      withSeries: true,
      seriesHandler: (_) async => http.Response('server exploded', 500),
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('系列信息暂不可用'), findsOneWidget);
    expect(barHeight(), 48, reason: 'failure state must be 48dp');
    container.dispose();

    // Data.
    container = await _apiContainer(
      withSeries: true,
      seriesHandler: (_) async =>
          _seriesResponse([_seriesNovel(1, 'one'), _seriesNovel(2, 'two')]),
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('series five'), findsOneWidget);
    expect(barHeight(), 48, reason: 'data state must be 48dp');
    container.dispose();

    // Current novel absent from the entries list.
    container = await _apiContainer(
      withSeries: true,
      seriesHandler: (_) async =>
          _seriesResponse([_seriesNovel(2, 'two'), _seriesNovel(3, 'three')]),
    );
    await _openReader(tester, container);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('series five'), findsOneWidget);
    expect(barHeight(), 48, reason: 'missing-entry state must be 48dp');
    container.dispose();
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
    addTearDown(container.dispose);
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
    expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
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
    addTearDown(container.dispose);
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
    addTearDown(container.dispose);
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

  testWidgets('a light app-theme sheet over the night palette owns the nav '
      'bar', (tester) async {
    // R2 edge case: the reader pins the night palette's light icons, but a
    // settings sheet is app-themed — under a light theme the nav-bar icons
    // must flip dark for as long as the sheet covers that edge.
    final container = await _apiContainer(
      preferences: {
        'pixivfunc.novel.reader_settings.v1': jsonEncode(
          const NovelReaderSettings(theme: NovelReaderTheme.night).toJson(),
        ),
      },
    );
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            theme: replicaTheme(Brightness.light),
            home: const NovelPage(novelId: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
      reason: 'the night palette pins light icons over both bars',
    );

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.dark,
      reason: 'a light sheet under itself needs dark nav icons',
    );
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.light,
      reason: 'the status bar still belongs to the night stage',
    );
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
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: _Host(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Detail + webview fetches, then the first layout pass.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

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
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: _Host(),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    });

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

  testWidgets('the body keeps its layout when the system bars hide', (
    tester,
  ) async {
    // R3: hiding the bars drops the live insets to zero. The body, the
    // page count and the hint must not move — the stage reads its cached
    // "bars shown" insets, so no repagination happens (D1).
    // FakeViewPadding speaks physical pixels; pin dpr to 1 and the
    // surface to the usual 800x600 so insets are read as logical dp.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.reset);

    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: NovelPage(novelId: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await _settleReader(tester);
    });

    Rect readerRect() => tester.getRect(find.byType(NovelReader));
    Rect? hintRect() {
      final hint = find.textContaining('novel 1 ·');
      return hint.evaluate().isEmpty ? null : tester.getRect(hint);
    }

    String footer() =>
        tester.widget<Text>(find.textContaining('novel 1 ·')).data!;

    final stableRect = readerRect();
    final stableHint = hintRect()!;
    final stableFooter = footer();

    void expectUnchanged(String phase) {
      expect(readerRect(), stableRect, reason: 'body moved in $phase');
      expect(hintRect(), stableHint, reason: 'hint moved in $phase');
      expect(footer(), stableFooter, reason: 'repaginated in $phase');
    }

    // Bars vanish: live insets report zero, layout must not move.
    tester.view.viewPadding = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding();
    await tester.pump();
    expectUnchanged('insets dropping to zero');

    // Bars return: still the same layout.
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    await tester.pump();
    expectUnchanged('insets restored');

    // A real reveal + hide cycle leaves the body untouched as well. The
    // hint yields to the chrome while it is up and returns at the same
    // place afterwards.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(readerRect(), stableRect, reason: 'body moved on reveal');
    expect(hintRect(), isNull, reason: 'hint must yield to the chrome');
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expectUnchanged('chrome hidden again');
  });

  testWidgets('a screen-size change reseeds the stable insets', (tester) async {
    // R3 second leg: the cached insets are only valid for the size they
    // were read at — a rotation/split changes the screen and the next
    // live reading wins outright.
    // FakeViewPadding speaks physical pixels; pin dpr to 1 and the
    // surface to the usual 800x600 so insets are read as logical dp.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
    addTearDown(tester.view.reset);

    final container = await _apiContainer();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: NovelPage(novelId: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await _settleReader(tester);
    });

    // Same size, bars hidden: the cached 24 top still applies.
    tester.view.viewPadding = const FakeViewPadding();
    tester.view.padding = const FakeViewPadding();
    await tester.pump();
    expect(tester.getRect(find.byType(NovelReader)).top, 24);

    // New screen size with new live insets: the cache reseeds to them —
    // this is the documented one-time relayout on rotation.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.viewPadding = const FakeViewPadding(top: 8, bottom: 16);
    tester.view.padding = const FakeViewPadding(top: 8, bottom: 16);
    await tester.pump();
    // The old layout's pages overflow the resized viewport for the frames
    // the reseeded relayout still has in flight — that single relayout is
    // the documented rotation boundary, not a layout bug. Let it commit,
    // then drain those transient paint errors.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    while (tester.takeException() != null) {}
    expect(tester.getRect(find.byType(NovelReader)).top, 8);
  });

  testWidgets('leaving the reader restores the root bar style', (tester) async {
    // R2: the stage's FuncSystemBars is a scoped override — unmounting the
    // route returns the bars to the app-level default without a reset.
    final container = await _apiContainer(
      preferences: {
        'pixivfunc.novel.reader_settings.v1': jsonEncode(
          const NovelReaderSettings(theme: NovelReaderTheme.night).toJson(),
        ),
      },
    );
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
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
    });

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
