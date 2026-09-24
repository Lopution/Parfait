import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/new/new_feed_models.dart';
import 'package:pixiv_func/core/new/new_feed_repository.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

class _FakeNewFeedRepository implements NewFeedRepository {
  _FakeNewFeedRepository({this.illustCount = 0});

  /// Non-zero makes the illust feed overflow the viewport so scroll-state
  /// assertions (re-tap → top) have something to scroll.
  final int illustCount;
  final requests = <NewFeedKey>[];

  @override
  Future<NewIllustPage> fetchIllust(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(key);
    return NewIllustPage(
      illusts: [
        for (var i = 0; i < illustCount; i++) parseIllust(illustJson(1000 + i)),
      ],
      nextUrl: null,
    );
  }

  @override
  Future<NewNovelPage> fetchNovel(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(key);
    return const NewNovelPage(novels: [], nextUrl: null);
  }

  @override
  bool validateIllustCursor(NewFeedKey key, {required String cursor}) => true;

  @override
  bool validateNovelCursor(NewFeedKey key, {required String cursor}) => true;
}

/// `illustStoreProvider` rebuilds when the account store resolves, so the
/// widget tests need the same credential/metadata overrides the feed tests
/// use — and the account future must be awaited before pumping or the
/// feed refetches once on resolution (same pattern as
/// recommended_home_test's world).
Future<(ProviderContainer, _FakeNewFeedRepository)> _makeWorld({
  int illustCount = 0,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final repository = _FakeNewFeedRepository(illustCount: illustCount);
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen');
          }),
        ),
      ),
      newFeedRepositoryProvider.overrideWithValue(repository),
    ],
  );
  await container.read(accountStoreProvider.future);
  return (container, repository);
}

Widget _app(ProviderContainer container, {NewPage? page}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: page ?? const NewPage(),
    ),
  );
}

void main() {
  test('NewFeedKey keeps scope and content type independent', () {
    const followingIllust = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.illust,
    );
    const followingNovel = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.novel,
    );
    const everyoneIllust = NewFeedKey(
      scope: NewFeedScope.everyone,
      type: NewFeedType.illust,
    );

    expect(followingIllust, isNot(followingNovel));
    expect(followingIllust, isNot(everyoneIllust));
    expect({followingIllust, followingNovel}, hasLength(2));
  });

  testWidgets('New tabs are lazy and the type selector stays visible', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pump();
    await tester.pump();

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('大家'), findsOneWidget);
    expect(find.text('好P友'), findsOneWidget);
    // The type selector is persistent chrome now — both chips exist before
    // any re-tap (the old expand-on-re-tap behavior is gone).
    expect(find.text('插画'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(repository.requests, [
      const NewFeedKey(scope: NewFeedScope.following, type: NewFeedType.illust),
    ]);

    await tester.tap(find.text('大家'));
    await tester.pumpAndSettle();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(
          scope: NewFeedScope.everyone,
          type: NewFeedType.illust,
        ),
      ),
    );
    // Re-tapping the active scope must not collapse the selector or
    // refetch — it is a scroll-only gesture now.
    await tester.tap(find.text('大家'));
    await tester.pumpAndSettle();
    expect(find.text('插画'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);

    await tester.tap(find.text('小说'));
    await tester.pump();
    await tester.pump();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(scope: NewFeedScope.everyone, type: NewFeedType.novel),
      ),
    );
  });

  testWidgets('re-tapping the active scope or type scrolls the feed to top', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final feedView = find.byType(CustomScrollView);
      expect(feedView, findsOneWidget);
      ScrollController controller() =>
          tester.widget<CustomScrollView>(feedView).controller!;

      // A programmatic jump stages the "scrolled away" state deterministi-
      // cally — the assertion is about the re-tap landing, not gestures.
      controller().jumpTo(400);
      await tester.pump();
      expect(controller().offset, 400);

      // Same-index scope tap → pure scroll-to-top.
      await tester.tap(find.text('关注'));
      await tester.pumpAndSettle();
      expect(controller().offset, 0);
      // Nothing refetched and the selector did not collapse.
      expect(repository.requests, [
        const NewFeedKey(
          scope: NewFeedScope.following,
          type: NewFeedType.illust,
        ),
      ]);
      expect(find.text('小说'), findsOneWidget);

      // Same-type chip tap → same scroll-only contract.
      controller().jumpTo(300);
      await tester.pump();
      expect(controller().offset, 300);
      await tester.tap(find.text('插画'));
      await tester.pumpAndSettle();
      expect(controller().offset, 0);
    });
  });

  testWidgets('branch re-tap scrolls the feed to top — no refetch, no '
      'selector expansion', (tester) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    final router = createPixivRouter(initialLocation: '/new');
    addTearDown(router.dispose);
    // Compact viewport: ≥600px swaps the bottom bar for a rail and the
    // re-tap channel has no tap surface.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
      await tester.pump();
      await tester.pumpAndSettle();

      final feedView = find.byType(CustomScrollView);
      expect(feedView, findsOneWidget);
      final controller = tester.widget<CustomScrollView>(feedView).controller!;
      controller.jumpTo(400);
      await tester.pump();
      expect(controller.offset, 400);

      // Same-destination tap on the bottom-bar "new" slot. Pure
      // scroll-to-top: no refetch, and the persistent scope/type chrome
      // must not expand or collapse — the old expand-on-re-tap entry is
      // gone for good.
      final requestsBefore = repository.requests.length;
      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.n),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
      expect(repository.requests.length, requestsBefore);
      expect(find.text('插画'), findsOneWidget);
      expect(find.text('小说'), findsOneWidget);
      expect(find.text('关注'), findsOneWidget);
    });
  });

  testWidgets('scope and type round-trip through the route parameters', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    final router = createPixivRouter(
      initialLocation: '/new?scope=everyone&type=novel',
    );
    addTearDown(router.dispose);
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
    await tester.pump();
    await tester.pumpAndSettle();

    // The URL seeds both selectors.
    var page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.everyone);
    expect(page.initialType, NewFeedType.novel);
    expect(repository.requests, [
      const NewFeedKey(scope: NewFeedScope.everyone, type: NewFeedType.novel),
    ]);

    // A scope tap writes scope+type back through context.replace.
    await tester.tap(find.text('好P友'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/new');
    expect(router.state.uri.queryParameters['scope'], 'myPixiv');
    expect(router.state.uri.queryParameters['type'], 'novel');
    page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.myPixiv);
    expect(page.initialType, NewFeedType.novel);

    // Same for the type selector.
    await tester.tap(find.text('插画'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['scope'], 'myPixiv');
    expect(router.state.uri.queryParameters['type'], 'illust');
    page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.myPixiv);
    expect(page.initialType, NewFeedType.illust);
  });
}
