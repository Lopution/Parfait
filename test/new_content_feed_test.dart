import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart' as legacy_material;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/new/new_feed_models.dart';
import 'package:parfait/core/new/new_feed_repository.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/features/new/new_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

Map<String, dynamic> _novelJson(int id) => {
  'id': id,
  'title': 'novel $id',
  'caption': '',
  'restrict': 0,
  'x_restrict': 0,
  'image_urls': {'medium': 'https://i.pximg.net/$id/m.png'},
  'tags': <Object>[],
  'text_length': 1200,
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'is_bookmarked': false,
  'visible': true,
};

class _FakeNewFeedRepository implements NewFeedRepository {
  _FakeNewFeedRepository({this.illustCount = 0, this.novelCount = 0});

  /// Non-zero makes the illust feed overflow the viewport so scroll-state
  /// assertions (re-tap → top) have something to scroll.
  final int illustCount;
  final int novelCount;

  /// When set, every fetch awaits this completer — holds an initial load
  /// or a pull-to-refresh in flight until the test completes it.
  Completer<void>? pendingFetch;

  /// When true, every fetch throws — drives the feed's error branch.
  var fails = false;

  final requests = <NewFeedKey>[];

  @override
  Future<NewIllustPage> fetchIllust(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(key);
    if (fails) throw ApiNetworkError(StateError('offline'));
    await pendingFetch?.future;
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
    if (fails) throw ApiNetworkError(StateError('offline'));
    await pendingFetch?.future;
    return NewNovelPage(
      novels: [
        for (var i = 0; i < novelCount; i++)
          NovelEntity.fromJson(_novelJson(2000 + i)),
      ],
      nextUrl: null,
    );
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
  int novelCount = 0,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final repository = _FakeNewFeedRepository(
    illustCount: illustCount,
    novelCount: novelCount,
  );
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
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

Widget _routerApp(ProviderContainer container, GoRouter router) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      routerConfig: router,
    ),
  );
}

/// Compact viewport: ≥600px swaps the bottom bar for a rail.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const _followingIllust = NewFeedKey(
  scope: NewFeedScope.following,
  type: NewFeedType.illust,
);

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
    const followingNovel = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.novel,
    );
    const everyoneIllust = NewFeedKey(
      scope: NewFeedScope.everyone,
      type: NewFeedType.illust,
    );

    expect(_followingIllust, isNot(followingNovel));
    expect(_followingIllust, isNot(everyoneIllust));
    expect({_followingIllust, followingNovel}, hasLength(2));
  });

  testWidgets('re-tapping the active scope scrolls the feed to top', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      // Adjacent scope slots stay mounted for swipe warmup — restrict
      // scroll-state queries to the onstage feed.
      final feedView = find.byType(CustomScrollView).hitTestable();
      expect(feedView, findsOneWidget);
      final controller = tester.widget<CustomScrollView>(feedView).controller!;

      // A programmatic jump stages the "scrolled away" state deterministi-
      // cally — the assertion is about the re-tap landing, not gestures.
      controller.jumpTo(400);
      await tester.pump();
      expect(controller.offset, 400);

      // Same-index scope tap → pure scroll-to-top, nothing refetched.
      await tester.tap(find.text('关注'));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(repository.requests, [_followingIllust]);
    });
  });

  testWidgets('branch re-tap scrolls the feed to top — no refetch', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    final router = createPixivRouter(initialLocation: '/new');
    addTearDown(router.dispose);
    _phone(tester);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_routerApp(container, router));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final feedView = find.byType(CustomScrollView);
      expect(feedView, findsOneWidget);
      final controller = tester.widget<CustomScrollView>(feedView).controller!;
      controller.jumpTo(400);
      await tester.pump();
      expect(controller.offset, 400);

      // Same-destination tap on the bottom-bar "new" slot.
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
      expect(find.text('关注'), findsOneWidget);
    });
  });

  testWidgets('a re-tap on a feed already at the top refreshes it', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    final router = createPixivRouter(initialLocation: '/new');
    addTearDown(router.dispose);
    _phone(tester);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_routerApp(container, router));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(controller.offset, 0);

      final requestsBefore = repository.requests.length;
      repository.pendingFetch = Completer<void>();
      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.n),
        ),
      );
      // As after a release: the overscroll springs onto the trigger, then
      // the refresh starts.
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The pull's own indicator shows the refresh in flight.
      expect(
        find.byType(legacy_material.RefreshProgressIndicator),
        findsOneWidget,
      );
      expect(repository.requests.length, requestsBefore + 1);

      repository.pendingFetch!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byType(legacy_material.RefreshProgressIndicator),
        findsNothing,
      );
      expect(controller.offset, 0);

      // The in-page scope re-tap follows the same rule.
      repository.pendingFetch = null;
      await tester.tap(find.text('关注'));
      await tester.pumpAndSettle();
      expect(repository.requests.length, requestsBefore + 2);
    });
  });

  testWidgets('the book button pushes the novel page; back keeps the illust '
      'feed where it was', (tester) async {
    final (container, repository) = await _makeWorld(
      illustCount: 24,
      novelCount: 3,
    );
    addTearDown(container.dispose);
    final router = createPixivRouter(initialLocation: '/new?scope=everyone');
    addTearDown(router.dispose);
    _phone(tester);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_routerApp(container, router));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final illustFeed = find.byType(CustomScrollView);
      final illustController = tester
          .widget<CustomScrollView>(illustFeed)
          .controller!;
      illustController.jumpTo(400);
      await tester.pump();

      await tester.tap(find.byTooltip('小说新作'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/new/new-novels');
      expect(find.text('novel 2000').hitTestable(), findsOneWidget);
      // The novel page opens on its own default scope.
      expect(
        repository.requests.last,
        const NewFeedKey(
          scope: NewFeedScope.following,
          type: NewFeedType.novel,
        ),
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/new');
      expect(router.state.uri.queryParameters, {'scope': 'everyone'});
      expect(illustController.offset, 400);
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
        NewFeedScope.values.indexOf(NewFeedScope.everyone),
      );
    });
  });
}
