import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/new/new_feed_controller.dart';
import 'package:parfait/core/new/new_feed_models.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/new/new_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

/// The App API's New feeds. Each answers one page: [illustCount] works
/// from 1000 or [novelCount] novels from 2000, the [r18] ids as R-18.
/// [requests] logs each read from the wire as its feed.
class _NewFeeds {
  _NewFeeds({this.illustCount = 0, this.novelCount = 0});

  /// Non-zero makes the illust feed overflow the viewport so scroll-state
  /// assertions (re-tap → top) have something to scroll.
  final int illustCount;
  final int novelCount;

  /// When set, every answer waits on it — holds an initial load or a
  /// pull-to-refresh in flight until the test completes it.
  Completer<void>? pendingFetch;

  /// Ids served as R-18.
  var r18 = <int>{};

  final requests = <NewFeedKey>[];

  static const _feeds = {
    '/v2/illust/follow': _followingIllust,
    '/v1/illust/new': NewFeedKey(
      scope: NewFeedScope.everyone,
      type: NewFeedType.illust,
    ),
    '/v2/illust/mypixiv': NewFeedKey(
      scope: NewFeedScope.myPixiv,
      type: NewFeedType.illust,
    ),
    '/v1/novel/follow': NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.novel,
    ),
    '/v1/novel/new': NewFeedKey(
      scope: NewFeedScope.everyone,
      type: NewFeedType.novel,
    ),
    '/v1/novel/mypixiv': NewFeedKey(
      scope: NewFeedScope.myPixiv,
      type: NewFeedType.novel,
    ),
  };

  Map<String, ApiRoute> get routes => {
    for (final MapEntry(key: path, value: feed) in _feeds.entries)
      path: (request) async {
        requests.add(feed);
        await pendingFetch?.future;
        int restrict(int id) => r18.contains(id) ? 1 : 0;
        return jsonResponse(
          feed.type == NewFeedType.illust
              ? pageJson('illusts', [
                  for (var id = 1000; id < 1000 + illustCount; id++)
                    illustJson(id, xRestrict: restrict(id)),
                ])
              : pageJson('novels', [
                  for (var id = 2000; id < 2000 + novelCount; id++)
                    {...novelJson(id), 'x_restrict': restrict(id)},
                ]),
        );
      },
  };
}

/// Signed in over [PixivApi] with the New feeds and what the shell reads.
/// The account future is awaited before pumping, or the feed refetches
/// once on resolution.
Future<(ProviderContainer, _NewFeeds)> _makeWorld({
  int illustCount = 0,
  int novelCount = 0,
}) async {
  final feeds = _NewFeeds(illustCount: illustCount, novelCount: novelCount);
  final container = await signedInApiContainer(
    PixivApi({...backgroundRoutes, ...shellRoutes, ...feeds.routes}).client,
    overrides: [
      feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
    ],
  );
  return (container, feeds);
}

Widget _routerApp(ProviderContainer container, GoRouter router) {
  return localizedRouterApp(router, container: container);
}

/// Compact viewport: ≥600px swaps the bottom bar for a rail.
void _phone(WidgetTester tester) {
  setViewSize(tester, const Size(390, 844));
}

const _followingIllust = NewFeedKey(
  scope: NewFeedScope.following,
  type: NewFeedType.illust,
);

Widget _app(ProviderContainer container, {NewPage? page}) {
  return localizedApp(container: container, home: page ?? const NewPage());
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

  test('the local block filters New works and novels (R7)', () async {
    await seedFilterSettings(blockR18: true);
    final (container, repository) = await _makeWorld(
      illustCount: 2,
      novelCount: 2,
    );
    repository.r18 = {1000, 2000};
    await container.read(settingsProvider.future);
    for (final (type, shown) in [
      (NewFeedType.illust, [1001]),
      (NewFeedType.novel, [2001]),
    ]) {
      final feed = newFeedProvider(
        NewFeedKey(scope: NewFeedScope.everyone, type: type),
      );
      container.listen(feed, (_, _) {});
      expect((await container.read(feed.future)).ids, shown);
    }
  });

  testWidgets('re-tapping the active scope scrolls the feed to top', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    await tester.pumpWidget(_app(container));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // Adjacent scope slots stay mounted for swipe warmup — restrict
    // scroll-state queries to the onstage feed.
    final feedView = find.bySubtype<CustomScrollView>().hitTestable();
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

  testWidgets('branch re-tap scrolls the feed to top — no refetch', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    final router = pixivRouter('/new');
    _phone(tester);

    await tester.pumpWidget(_routerApp(container, router));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final feedView = find.bySubtype<CustomScrollView>();
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

  testWidgets('a re-tap on a feed already at the top refreshes it', (
    tester,
  ) async {
    final (container, repository) = await _makeWorld(illustCount: 24);
    final router = pixivRouter('/new');
    _phone(tester);

    await tester.pumpWidget(_routerApp(container, router));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    // The tab next to it is built too, off screen.
    final controller = tester
        .widget<CustomScrollView>(
          find.bySubtype<CustomScrollView>().hitTestable(),
        )
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
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(repository.requests.length, requestsBefore + 1);

    repository.pendingFetch!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(controller.offset, 0);

    // The in-page scope re-tap follows the same rule.
    repository.pendingFetch = null;
    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();
    expect(repository.requests.length, requestsBefore + 2);
  });

  testWidgets('the book button pushes the novel page; back keeps the illust '
      'feed where it was', (tester) async {
    final (container, repository) = await _makeWorld(
      illustCount: 24,
      novelCount: 3,
    );
    final router = pixivRouter('/new?scope=everyone');
    _phone(tester);

    await tester.pumpWidget(_routerApp(container, router));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final illustFeed = find.bySubtype<CustomScrollView>().hitTestable();
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
      const NewFeedKey(scope: NewFeedScope.following, type: NewFeedType.novel),
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
}
