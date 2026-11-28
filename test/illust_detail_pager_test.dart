import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/feed/illust_pager_source.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/detail_world.dart';
import 'helpers/history_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';

Future<void> _pumpPager(
  WidgetTester tester,
  ProviderContainer container, {
  required IllustPagerSource source,
  required int initialId,
  Size surface = const Size(390, 844),
  TransitionBuilder? builder,
}) async {
  setViewSize(tester, surface);
  await tester.pumpWidget(
    localizedApp(
      container: container,
      builder: builder,
      home: IllustDetailPagerPage(source: source, initialIllustId: initialId),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) =>
    pumpUntil(
      tester,
      condition,
      step: const Duration(milliseconds: 8),
      frames: 120,
    );

double _page(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!.page!;

Offset _swipeOrigin(WidgetTester tester) =>
    tester.getTopLeft(find.byType(PageView)) + const Offset(195, 200);

Finder _detail(int id) => find.byWidgetPredicate(
  (w) => w is IllustDetailPage && w.illustId == id,
  skipOffstage: false,
);

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    answerConnectivityChannels();
  });

  testWidgets('swiping sideways moves through the feed order', (tester) async {
    final (container, _, _) = await makeWorld();
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 42);

    expect(_page(tester), 0);
    expect(
      tester
          .widget<IllustDetailPage>(find.byType(IllustDetailPage).first)
          .illustId,
      42,
    );

    await tester.flingFrom(_swipeOrigin(tester), const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);

    await tester.flingFrom(_swipeOrigin(tester), const Offset(260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 0);
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

    await tester.flingFrom(_swipeOrigin(tester), const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);
    expect(calls, 0);

    for (var i = 0; i < 6; i++) {
      await tester.flingFrom(_swipeOrigin(tester), const Offset(-260, 0), 900);
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

    await tester.flingFrom(_swipeOrigin(tester), const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);

    source.update(const [41, 42, 43, 44]);
    await tester.pump();
    await tester.pump();
    expect(_page(tester), 2);
    expect(
      find.byWidgetPredicate((w) => w is IllustDetailPage && w.illustId == 43),
      findsOneWidget,
    );
  });

  testWidgets('only the visible page owns a live hero', (tester) async {
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

    await tester.flingFrom(_swipeOrigin(tester), const Offset(-260, 0), 900);
    await tester.pumpAndSettle();
    expect(_page(tester), 1);
    expect(source.cardFlies(43), isFalse);
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

  testWidgets('only the settled page writes to the history', (tester) async {
    late HistoryRepository history;
    await tester.runAsync(
      () async => history = await openHistoryRepository(const []),
    );
    final (container, _, _) = await makeWorld(
      extraOverrides: [
        historyRepositoryProvider.overrideWithValue(history),
        imageWorkerProvider.overrideWithValue(stalledImageWorker()),
      ],
    );
    container.read(illustStoreProvider).mergeAll([
      for (final id in [42, 43, 44]) parseIllust(illustJson(id)),
    ]);
    final source = IllustPagerSource()..update(const [42, 43, 44]);
    await _pumpPager(tester, container, source: source, initialId: 43);
    final account = container.read(historyAccountIdProvider)!;
    Future<List<int>> recorded() async {
      await settleHistory(tester, history);
      final page = await tester.runAsync(
        () => history.page(accountId: account),
      );
      return [for (final record in page!.records) record.contentId];
    }

    expect(_detail(42), findsOneWidget);
    expect(_detail(44), findsOneWidget);
    expect(await recorded(), [43], reason: 'prebuilt neighbours unseen');

    final gesture = await tester.startGesture(_swipeOrigin(tester));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-280, 0));
    await gesture.up();
    await _pumpUntil(tester, () => _page(tester) == 2);
    await tester.pump(IllustDetailPagerPage.activeDwell);
    await tester.pumpWidget(const SizedBox());
    expect((await recorded()).toSet(), {43, 44});
  });

  group('related works on demand', () {
    const ids = [42, 43, 44];
    const tall = Size(390, 2400);

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
      await _pumpPager(
        tester,
        container,
        source: source,
        initialId: 43,
        surface: tall,
      );
      expect(_detail(42), findsOneWidget);
      expect(_detail(44), findsOneWidget);
      expect(log, [43], reason: 'prebuilt neighbours stay quiet');
    });

    testWidgets('a neighbour requests once it has stayed settled', (
      tester,
    ) async {
      final (container, log) = await shortWorld();
      final source = IllustPagerSource()..update(ids);
      await _pumpPager(
        tester,
        container,
        source: source,
        initialId: 42,
        surface: tall,
      );
      expect(log, [42]);

      final gesture = await tester.startGesture(_swipeOrigin(tester));
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(log, [42]);

      await gesture.moveBy(const Offset(-200, 0));
      await gesture.up();
      await _pumpUntil(tester, () => _page(tester) == 1);
      expect(log, [42], reason: 'a page just settled on sends nothing yet');

      final currentScroll = find.descendant(
        of: _detail(43),
        matching: find.byType(Scrollable),
      );
      final position = tester
          .state<ScrollableState>(currentScroll.first)
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      await tester.pump();

      await tester.pump(IllustDetailPagerPage.activeDwell);
      await tester.pump();
      expect(log, [42, 43]);
    });
  });

  testWidgets('the pager image flies back only to a card on screen', (
    tester,
  ) async {
    final (container, _, _) = await makeWorld();
    final source = IllustPagerSource();
    await tester.pumpWidget(
      localizedApp(
        container: container,
        body: IllustPagerScope(
          source: source,
          child: ListView(
            children: [
              for (final id in [1, 2, 3])
                SizedBox(
                  height: 400,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 150,
                      child: IllustCard(entity: parseIllust(illustJson(id))),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    bool flies(int id) => tester
        .widget<HeroMode>(
          find
              .ancestor(
                of: find.byWidgetPredicate(
                  (w) => w is Hero && w.tag == illustHeroTag('feed', id),
                  skipOffstage: false,
                ),
                matching: find.byType(HeroMode, skipOffstage: false),
              )
              .first,
        )
        .enabled;

    for (final (id, onScreen) in [(1, true), (3, false), (2, true)]) {
      source.aimHomeFlight(id);
      await tester.pump();
      expect(flies(id), onScreen, reason: 'card $id');
    }
    source
      ..aimHomeFlight(3)
      ..clearHomeFlight();
    await tester.pump();
    expect(flies(3), isTrue);
  });
}
