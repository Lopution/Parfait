import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
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

  testWidgets('New tabs are lazy and re-tap opens the type selector', (
    tester,
  ) async {
    final repository = _FakeNewFeedRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newFeedRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),

          home: const NewPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('大家'), findsOneWidget);
    expect(find.text('好P友'), findsOneWidget);
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

    await tester.tap(find.text('大家'));
    await tester.pumpAndSettle();
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
  });
}
