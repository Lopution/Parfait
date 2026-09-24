import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/features/novel/novel_page.dart';
import 'package:pixiv_func/features/novel/novel_reader_stage.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

Future<ProviderContainer> _apiContainer() async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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
      return http.Response('not found', 404);
    }),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return container;
}

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
    // so it must not be on screen yet (no duplicate title either).
    expect(find.text('novel 1'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    // Center tap reveals the chrome; the title appears exactly once.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('novel 1'), findsOneWidget);
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
