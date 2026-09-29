import 'dart:async';

import 'package:flutter/material.dart' as legacy_material;
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
import 'package:pixiv_func/core/paging/feed_snapshot_store.dart';
import 'package:pixiv_func/app/widgets/app_type_switch.dart';
import 'package:pixiv_func/app/widgets/feed/feed_states.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/app/widgets/skeleton/illust_grid_skeleton.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/new/new_feed_models.dart';
import 'package:pixiv_func/core/new/new_feed_repository.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

class _FakeNewFeedRepository implements NewFeedRepository {
  _FakeNewFeedRepository({this.illustCount = 0});

  /// Non-zero makes the illust feed overflow the viewport so scroll-state
  /// assertions (re-tap → top) have something to scroll.
  final int illustCount;

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

/// `SmoothWheelScroll` starts in wheel mode on the Linux test host
/// (desktop = true): the scrollable sits on NeverScrollableScrollPhysics
/// until the first pointer-down drops the mode. A stray >slop drag is a
/// safe warm-up — it is not a tap, so cards cannot navigate.
Future<void> _dropWheelMode(WidgetTester tester, Finder feedView) async {
  await tester.drag(feedView, const Offset(0, -30));
  await tester.pump();
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
    // The type row lives inside the feed now — at rest it is mounted, so
    // both segments exist before any re-tap (the old expand-on-re-tap
    // behavior is gone). Hit-testable finders skip the offstage scope
    // slots the swipe warmer keeps alive.
    expect(find.text('插画').hitTestable(), findsOneWidget);
    expect(find.text('小说').hitTestable(), findsOneWidget);
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
    // Re-tapping the active scope must not collapse the row or
    // refetch — it is a scroll-only gesture now.
    await tester.tap(find.text('大家'));
    await tester.pumpAndSettle();
    expect(find.text('插画').hitTestable(), findsOneWidget);
    expect(find.text('小说').hitTestable(), findsOneWidget);

    await tester.tap(find.text('小说').hitTestable());
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

      // Adjacent scope slots stay mounted for swipe warmup — restrict
      // scroll-state queries to the onstage feed.
      final feedView = find.byType(CustomScrollView).hitTestable();
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
      // Nothing refetched and the row is back at the top with the feed.
      expect(repository.requests, [
        const NewFeedKey(
          scope: NewFeedScope.following,
          type: NewFeedType.illust,
        ),
      ]);
      expect(find.text('小说').hitTestable(), findsOneWidget);

      // Same-type segment tap → same scroll-only contract. The row
      // scrolled away with the feed: a reverse drag floats it back — the
      // reveal consumes the drag delta, so the offset does not move yet.
      controller().jumpTo(300);
      await tester.pump();
      expect(controller().offset, 300);
      await _dropWheelMode(tester, feedView);
      await tester.drag(feedView, const Offset(0, 50));
      await tester.pump();
      await tester.pumpAndSettle();
      final row = find.byType(AppTypeSwitch<NewFeedType>).hitTestable();
      expect(row, findsOneWidget);
      await tester.tap(find.descendant(of: row, matching: find.text('插画')));
      await tester.pumpAndSettle();
      expect(controller().offset, 0);
      // Once back at the top the row sits in its natural slot.
      expect(row, findsOneWidget);
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
      // scroll-to-top: no refetch, and the scope/type chrome must not
      // expand or collapse — the old expand-on-re-tap entry is gone for
      // good.
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

    // Same for the type row.
    await tester.tap(find.text('插画').hitTestable());
    await tester.pump();
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['scope'], 'myPixiv');
    expect(router.state.uri.queryParameters['type'], 'illust');
    page = tester.widget<NewPage>(find.byType(NewPage));
    expect(page.initialScope, NewFeedScope.myPixiv);
    expect(page.initialType, NewFeedType.illust);
  });

  testWidgets('the type row caps at 48dp and scrolls away with the feed', (
    tester,
  ) async {
    final (container, _) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final row = find.byType(AppTypeSwitch<NewFeedType>).hitTestable();
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, lessThanOrEqualTo(48));

      final feedView = find.byType(CustomScrollView).hitTestable();
      await _dropWheelMode(tester, feedView);
      await tester.drag(feedView, const Offset(0, -400));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(row, findsNothing);
    });
  });

  testWidgets('a reverse drag floats the type row back in', (tester) async {
    final (container, _) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final row = find.byType(AppTypeSwitch<NewFeedType>).hitTestable();
      final feedView = find.byType(CustomScrollView).hitTestable();
      final controller = tester.widget<CustomScrollView>(feedView).controller!;
      controller.jumpTo(400);
      await tester.pump();
      expect(row, findsNothing);

      // The floating header consumes the reverse drag to reveal itself —
      // a full reveal needs at least the row's own extent.
      await _dropWheelMode(tester, feedView);
      await tester.drag(feedView, const Offset(0, 50));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(
        tester.getRect(row).top,
        lessThan(tester.getRect(feedView).top + 48),
      );
    });
  });

  testWidgets('the type row stays tappable while the feed is loading', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    repository.pendingFetch = Completer<void>();
    addTearDown(() {
      if (repository.pendingFetch?.isCompleted == false) {
        repository.pendingFetch!.complete();
      }
    });
    await tester.pumpWidget(_app(container));
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(AppTypeSwitch<NewFeedType>).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('小说').hitTestable());
    await tester.pump();
    await tester.pump();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(
          scope: NewFeedScope.following,
          type: NewFeedType.novel,
        ),
      ),
    );
    repository.pendingFetch!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('illust first load shows the grid skeleton, not an empty '
      'state', (tester) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    repository.pendingFetch = Completer<void>();
    addTearDown(() {
      if (repository.pendingFetch?.isCompleted == false) {
        repository.pendingFetch!.complete();
      }
    });
    await tester.pumpWidget(_app(container));
    await tester.pump();
    await tester.pump();

    expect(find.byType(IllustGridSkeleton), findsOneWidget);
    expect(find.byType(FeedEmpty), findsNothing);

    repository.pendingFetch!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('novel first load shows a spinner, not an empty state', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    repository.pendingFetch = Completer<void>();
    addTearDown(() {
      if (repository.pendingFetch?.isCompleted == false) {
        repository.pendingFetch!.complete();
      }
    });
    await tester.pumpWidget(
      _app(container, page: const NewPage(initialType: NewFeedType.novel)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(FeedLoading), findsOneWidget);
    expect(find.byType(IllustGridSkeleton), findsNothing);
    expect(find.byType(FeedEmpty), findsNothing);

    repository.pendingFetch!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('the type row stays tappable while the feed is in error', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    repository.fails = true;
    await tester.pumpWidget(_app(container));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byType(AppTypeSwitch<NewFeedType>).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('小说').hitTestable());
    await tester.pump();
    await tester.pump();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(
          scope: NewFeedScope.following,
          type: NewFeedType.novel,
        ),
      ),
    );
    // The tap's drag-cancel leaves a chained zero-delay indicator future —
    // settle so no fake timer is pending at teardown.
    await tester.pumpAndSettle();
  });

  testWidgets('the type row stays tappable while the feed is empty', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byType(AppTypeSwitch<NewFeedType>).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('小说').hitTestable());
    await tester.pump();
    await tester.pump();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(
          scope: NewFeedScope.following,
          type: NewFeedType.novel,
        ),
      ),
    );
  });

  /// Pull-to-refresh around the trigger threshold (design §9): the row is
  /// the first sliver, so it must ride with the overscroll, and the
  /// indicator must stay above it. The swipe warmer can mount a neighbor
  /// feed mid-gesture, so every finder is hit-testable and request counts
  /// are filtered to the active feed key.
  testWidgets('a pull under the threshold carries the row with the list', (
    tester,
  ) async {
    const activeKey = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.illust,
    );
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final row = find.byType(AppTypeSwitch<NewFeedType>).hitTestable();
      final card = find.byType(IllustCard).hitTestable().first;
      final indicator = find.byType(legacy_material.RefreshProgressIndicator);
      final feedView = find.byType(CustomScrollView).hitTestable();
      expect(row, findsOneWidget);
      expect(card, findsOneWidget);
      int activeRequests() =>
          repository.requests.where((key) => key == activeKey).length;
      final requestsBefore = activeRequests();
      final cardTop = tester.getRect(card).top;
      final rowTop = tester.getRect(row).top;

      // 60px < the 100px trigger — the gesture stays a drag, no refresh.
      await _dropWheelMode(tester, feedView);
      final gesture = await tester.startGesture(tester.getCenter(feedView));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump();
      }

      // The card must actually be displaced before comparing row motion.
      final cardDelta = tester.getRect(card).top - cardTop;
      expect(cardDelta, greaterThan(0));
      expect(
        tester.getRect(row).top - rowTop,
        moreOrLessEquals(cardDelta, epsilon: 0.01),
      );
      // The indicator stays above the row — its bottom must not cross
      // the row's top edge.
      expect(indicator, findsOneWidget);
      expect(
        tester.getRect(indicator).bottom,
        lessThanOrEqualTo(tester.getRect(row).top),
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(activeRequests(), requestsBefore);
    });
  });

  testWidgets('releasing past the threshold holds the refresh under the '
      'row', (tester) async {
    const activeKey = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.illust,
    );
    final (container, repository) = await _makeWorld(illustCount: 24);
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      final row = find.byType(AppTypeSwitch<NewFeedType>).hitTestable();
      final card = find.byType(IllustCard).hitTestable().first;
      final indicator = find.byType(legacy_material.RefreshProgressIndicator);
      final feedView = find.byType(CustomScrollView).hitTestable();
      int activeRequests() =>
          repository.requests.where((key) => key == activeKey).length;
      final requestsBefore = activeRequests();
      final cardTop = tester.getRect(card).top;
      final rowTop = tester.getRect(row).top;

      // The refresh request hangs on the gate so the processing state
      // stays observable: the list stays pinned at the trigger offset.
      repository.pendingFetch = Completer<void>();

      // Finger travel is damped by overscroll physics — pull_to_refresh_
      // test reaches the same trigger with one long drag.
      await _dropWheelMode(tester, feedView);
      final gesture = await tester.startGesture(tester.getCenter(feedView));
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
      }
      await gesture.up();
      // On release the list springs back to the trigger offset before the
      // refresh task fires — wait for the request to land.
      for (var i = 0; i < 40 && activeRequests() == requestsBefore; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(activeRequests(), requestsBefore + 1);

      final cardDelta = tester.getRect(card).top - cardTop;
      expect(cardDelta, greaterThan(0));
      expect(
        tester.getRect(row).top - rowTop,
        moreOrLessEquals(cardDelta, epsilon: 0.01),
      );
      expect(indicator, findsOneWidget);
      expect(
        tester.getRect(indicator).bottom,
        lessThanOrEqualTo(tester.getRect(row).top),
      );

      repository.pendingFetch!.complete();
      await tester.pump();
      await tester.pumpAndSettle();
    });
  });

  /// A swipe that starts on the type row must act like one that starts
  /// anywhere else on the feed: the two segments fit, so the row has
  /// nothing to scroll — it must neither overscroll into a refresh nor
  /// keep the swipe from RootSwipeSwitcher.
  group('a sideways swipe from the type row', () {
    /// Mounts the loaded feed the way a phone starts it: out of wheel
    /// mode, with the row at the top.
    Future<void> pumpLoadedFeed(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(_app(container));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      // The warm-up drag scrolls the row partly away; jump back.
      final feedView = find.byType(CustomScrollView).hitTestable();
      await _dropWheelMode(tester, feedView);
      tester.widget<CustomScrollView>(feedView).controller!.jumpTo(0);
      await tester.pumpAndSettle();
    }

    Finder segments() => find.descendant(
      of: find.byType(AppTypeSwitch<NewFeedType>).hitTestable(),
      matching: find.byType(SegmentedButton<NewFeedType>),
    );

    testWidgets('never refreshes the visible feed', (tester) async {
      const activeKey = NewFeedKey(
        scope: NewFeedScope.following,
        type: NewFeedType.illust,
      );
      final (container, repository) = await _makeWorld(illustCount: 24);
      addTearDown(container.dispose);
      await mockNetworkImagesFor(() async {
        await pumpLoadedFeed(tester, container);
        expect(segments(), findsOneWidget);
        int activeRequests() =>
            repository.requests.where((key) => key == activeKey).length;
        final requestsBefore = activeRequests();

        // Rightward on the first scope: there is no tab to turn back to,
        // so the drag has nowhere to go.
        await tester.drag(segments(), const Offset(300, 0));
        await tester.pumpAndSettle();
        expect(activeRequests(), requestsBefore);
      });
    });

    testWidgets('turns the scope tab', (tester) async {
      final (container, _) = await _makeWorld(illustCount: 24);
      addTearDown(container.dispose);
      await mockNetworkImagesFor(() async {
        await pumpLoadedFeed(tester, container);
        expect(segments(), findsOneWidget);
        final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;

        await tester.drag(segments(), const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(tabs.index, 1);
      });
    });
  });
}
