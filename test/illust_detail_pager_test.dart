import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/illust_fixtures.dart';
import 'illust_detail_page_test.dart';

Future<void> _pumpPager(
  WidgetTester tester,
  ProviderContainer container, {
  required IllustPagerSource source,
  required int initialId,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: IllustDetailPagerPage(
            source: source,
            initialIllustId: initialId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}

double _page(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!.page!;

/// A mounted detail page, on screen or in the pager's cache extent.
Finder _detail(int id) => find.byWidgetPredicate(
  (w) => w is IllustDetailPage && w.illustId == id,
  skipOffstage: false,
);

void main() {
  setUp(() {
    // Detail pages embed VisibilityDetector page trackers; a zero interval
    // uses post-frame callbacks instead of a periodic timer, which would
    // otherwise linger into test teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('swiping sideways moves through the feed order', (tester) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 42);

    final pager = find.byType(PageView);
    expect(_page(tester), 0);
    expect(
      tester
          .widget<IllustDetailPage>(find.byType(IllustDetailPage).first)
          .illustId,
      42,
    );

    await tester.fling(pager, const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);

    await tester.fling(pager, const Offset(260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 0);
  });

  testWidgets('pager stops at the first and last work — no wrap', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43]);
    await _pumpPager(tester, container, source: source, initialId: 42);
    final pager = find.byType(PageView);

    // First work, swipe right — stays on 0.
    await tester.fling(pager, const Offset(260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 0);

    // Last work, swipe left — stays on 1.
    await tester.fling(pager, const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    await tester.fling(pager, const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);
  });

  testWidgets('swiping near the end asks the feed for its next page', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    final ids = [for (var i = 0; i < 10; i++) 100 + i];
    container.read(illustStoreProvider).mergeAll([
      for (final id in ids) parseIllust(illustJson(id)),
    ]);
    var calls = 0;
    final source = IllustPagerSource()
      ..update(ids)
      ..onNearEnd = () => calls++;
    await _pumpPager(tester, container, source: source, initialId: 100);
    final pager = find.byType(PageView);

    // Below the threshold nothing fires.
    await tester.fling(pager, const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);
    expect(calls, 0);

    // Walk past `loadAhead` from the end — the feed's loadMore hook runs.
    for (var i = 0; i < 6; i++) {
      await tester.fling(pager, const Offset(-260, 0), 900);
      await tester.pumpAndSettle();
    }
    expect(_page(tester), 7);
    expect(calls, greaterThan(0));
  });

  testWidgets('a rewritten feed list keeps the viewport on the same work', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [41, 42, 43, 44]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 42);
    final pager = find.byType(PageView);

    await tester.fling(pager, const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1); // id 43

    // A refresh inserting at the head must re-seat the viewport on id 43,
    // not silently show whatever landed on index 1.
    source.update(const [41, 42, 43, 44]);
    // The reseat is a post-frame callback — one pump runs it, the jump
    // lands synchronously, one more settles the new page's build.
    await tester.pump();
    await tester.pump();
    expect(_page(tester), 2);
    expect(
      find.byWidgetPredicate((w) => w is IllustDetailPage && w.illustId == 43),
      findsOneWidget,
    );
  });

  testWidgets('a page landing mid-paging keeps the built detail pages', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44, 45]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 42);
    final before = tester.widget<IllustDetailPage>(_detail(42));

    // The feed re-publishes an equal list on every rebuild (a load-more
    // phase flip): nothing to re-seat.
    var notified = 0;
    source.addListener(() => notified++);
    source.update(const [42, 43, 44]);
    expect(notified, 0);

    // A real append re-seats the pager, but the built detail subtrees
    // must come through untouched.
    source.update(const [42, 43, 44, 45]);
    await tester.pump();
    await tester.pump();
    expect(notified, 1);
    expect(
      identical(tester.widget<IllustDetailPage>(_detail(42)), before),
      isTrue,
    );
  });

  testWidgets('only the visible page owns a live hero', (tester) async {
    // Adjacent pages pre-build for the swipe, but all three carry the feed
    // hero tag — without HeroMode gating, a push or pop would fly three
    // covers at once instead of the one under the finger.
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 42);

    final enabled = find.byWidgetPredicate((w) => w is HeroMode && w.enabled);
    expect(enabled, findsOneWidget);
    expect(
      find.descendant(
        of: enabled,
        matching: find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 42,
        ),
      ),
      findsOneWidget,
    );

    // After a swipe the live hero follows the committed page.
    await tester.fling(find.byType(PageView), const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);
    expect(enabled, findsOneWidget);
    expect(
      find.descendant(
        of: enabled,
        matching: find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 43,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('swiping keeps the sibling detail page instance alive', (
    tester,
  ) async {
    // allowImplicitScrolling builds the neighbour as the drag pulls it
    // into the window; the swipe commit only needs to move the HeroMode
    // gate — rebuilding the whole detail subtree mid-swipe is exactly
    // the device-reported hitch.
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 42);

    final page43 = find.byWidgetPredicate(
      (w) => w is IllustDetailPage && w.illustId == 43,
    );

    // Hold the drag mid-swipe: the incoming page has mounted but the
    // commit has not fired yet, so the captured widget predates it.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    for (var i = 0; i < 10 && page43.evaluate().isEmpty; i++) {
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(page43, findsOneWidget);
    final before = tester.widget<IllustDetailPage>(page43);

    // Push past the midpoint so the release commits to the next page.
    await gesture.moveBy(const Offset(-250, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_page(tester), 1);

    expect(
      identical(before, tester.widget<IllustDetailPage>(page43)),
      isTrue,
      reason:
          'the adjacent IllustDetailPage subtree must survive the '
          'page-change notify — only its HeroMode wrapper may rebuild',
    );

    // The hero gate still follows the committed page.
    final enabled = find.byWidgetPredicate((w) => w is HeroMode && w.enabled);
    expect(enabled, findsOneWidget);
    expect(
      find.descendant(
        of: enabled,
        matching: find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 43,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a page pulled in mid-swipe builds once the scroll settles', (
    tester,
  ) async {
    // The first drag frame pulls the page after next into the cache
    // extent; building its whole detail there was the swipe hitch.
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44, 45]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44, 45]);
    await _pumpPager(tester, container, source: source, initialId: 42);
    expect(_detail(43), findsOneWidget);
    expect(_detail(44), findsNothing);

    await mockNetworkImagesFor(() async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      for (var i = 0; i < 3; i++) {
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_page(tester), greaterThan(0));
      expect(_detail(44), findsNothing);

      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    });
    expect(_page(tester), 1);
    expect(_detail(44), findsOneWidget);
  });

  testWidgets('neighbours build after the push transition, not inside it', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [41, 42, 43]) parseIllust(illustJson(id)),
    ]);
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);
    final source = IllustPagerSource()..update(const [41, 42, 43]);
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
      unawaited(
        router.push<void>(
          '/recommended/illust/42',
          extra: IllustRouteExtra(pagerSource: source),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_detail(42), findsOneWidget);
      expect(_detail(41), findsNothing);
      expect(_detail(43), findsNothing);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(_detail(41), findsOneWidget);
      expect(_detail(43), findsOneWidget);
    });
  });

  testWidgets('a card feed exposes its work list to the detail route', (
    tester,
  ) async {
    // The route-level contract: IllustRouteExtra.pagerSource switches the
    // illust page to the pager; without it the single-work page mounts.
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43]) parseIllust(illustJson(id)),
    ]);
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);
    final source = IllustPagerSource()..update(const [42, 43]);
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
    });
    // push()'s future only completes when the route pops — don't await
    // it, just let the transition play out over bounded pumps.
    unawaited(
      router.push<void>(
        '/recommended/illust/42',
        extra: IllustRouteExtra(pagerSource: source),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byType(IllustDetailPagerPage), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('a route without a pager source mounts the single page', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([parseIllust(illustJson(42))]);
    final router = createPixivRouter(initialLocation: '/recommended');
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
    });
    unawaited(router.push<void>('/recommended/illust/42'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byType(IllustDetailPagerPage), findsNothing);
    expect(find.byType(IllustDetailPage), findsOneWidget);
  });

  testWidgets('grid exposes its pager source to card children', (tester) async {
    IllustPagerSource? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            IllustFeedGrid(
              itemCount: 2,
              itemIds: const [1, 2],
              itemBuilder: (context, index) {
                seen ??= IllustPagerScope.maybeOf(context);
                return const SizedBox(height: 100);
              },
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(seen?.ids, [1, 2]);
  });

  group('related works on demand', () {
    const ids = [42, 43, 44];

    /// Short single-page landscape works: the related section sits inside
    /// the first screen of every page, so only the activity gate keeps a
    /// neighbour from requesting.
    Future<(ProviderContainer, List<int>)> shortWorld() async {
      final log = <int>[];
      final (container, _, _) = await makeWorld(
        relatedLog: log,
        detailOverrides: {
          for (final id in ids) id: illustJson(id, width: 1200, height: 600),
        },
        relatedOverrides: {
          for (final id in ids) id: [illustJson(900 + id)],
        },
      );
      container.read(illustStoreProvider).mergeAll([
        for (final id in ids) parseIllust(illustJson(id)),
      ]);
      return (container, log);
    }

    testWidgets('only the current page requests its related works', (
      tester,
    ) async {
      final (container, log) = await shortWorld();
      final source = IllustPagerSource()..update(ids);
      await _pumpPager(tester, container, source: source, initialId: 43);
      expect(_detail(42), findsOneWidget);
      expect(_detail(44), findsOneWidget);
      expect(log, [43], reason: 'prebuilt neighbours stay quiet');
    });

    testWidgets('a neighbour requests once the swipe commits to it', (
      tester,
    ) async {
      final (container, log) = await shortWorld();
      final source = IllustPagerSource()..update(ids);
      await _pumpPager(tester, container, source: source, initialId: 42);
      expect(log, [42]);

      await mockNetworkImagesFor(() async {
        // Half a swipe brings the neighbour's section on screen while the
        // page is still not current.
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(PageView)),
        );
        await gesture.moveBy(const Offset(-40, 0));
        await gesture.moveBy(const Offset(-80, 0));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(log, [42]);

        await gesture.moveBy(const Offset(-200, 0));
        await gesture.up();
        await tester.pumpAndSettle();
      });
      expect(_page(tester), 1);
      expect(log, [42, 43]);
    });
  });
}
