import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/widgets/tab_swipe_switcher.dart';
import 'package:parfait/core/image/image_worker.dart';
import 'package:parfait/core/image/image_worker_client.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/touch.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
}) async {
  setViewSize(tester, const Size(390, 844));
  final router = pixivRouter(location);
  await tester.pumpWidget(
    localizedRouterApp(router, overrides: [...signedInAccountOverrides()]),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

String _path(GoRouter router) => router.routeInformationProvider.value.uri.path;

/// A committed sideways flick inside the visible branch page.
Future<void> _flingLeft(WidgetTester tester, Finder page) =>
    tester.fling(page, const Offset(-260, 0), 900);

TabController _tabController(WidgetTester tester, Finder page) => tester
    .widget<TabBar>(find.descendant(of: page, matching: find.byType(TabBar)))
    .controller!;

int _tabIndex(WidgetTester tester, Finder page) =>
    _tabController(tester, page).index;

/// Four tabs showing the second, images from [worker]; returns the tabs
/// built ahead, in order.
Future<List<int>> _pumpPreparing(
  WidgetTester tester,
  ImageWorker worker,
) async {
  final controller = TabController(
    length: 4,
    vsync: const TestVSync(),
    initialIndex: 1,
  );
  addTearDown(controller.dispose);
  final prepared = <int>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [imageWorkerProvider.overrideWithValue(worker)],
      child: MaterialApp(
        home: TabSwipeSwitcher(
          tabController: controller,
          prepareTab: (index) {
            if (prepared.contains(index)) return false;
            prepared.add(index);
            return true;
          },
          // A list to share the arena with, as a feed does: alone, the
          // drag would start on the down.
          child: ListView(children: const [SizedBox(height: 2000)]),
        ),
      ),
    ),
  );
  return prepared;
}

/// A bare switcher over [child] with [length] tabs on the first.
Future<TabController> _pumpTabs(
  WidgetTester tester, {
  required int length,
  Widget child = const SizedBox.expand(),
}) async {
  final controller = TabController(length: length, vsync: const TestVSync());
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: TabSwipeSwitcher(tabController: controller, child: child),
    ),
  );
  return controller;
}

void main() {
  testWidgets('sideways flings step the page\'s own top tabs', (tester) async {
    final router = await _pumpHome(tester);
    final page = find.byType(RecommendedHomePage);
    expect(_tabIndex(tester, page), 0);

    // Recommended has four tabs — each fling advances one.
    for (var i = 1; i <= 3; i++) {
      await _flingLeft(tester, page);
      await tester.pumpAndSettle();
      expect(_tabIndex(tester, page), i);
      expect(_path(router), '/recommended');
    }
  });

  testWidgets('a vertical fling never switches tabs', (tester) async {
    final router = await _pumpHome(tester);
    await tester.fling(
      find.byType(RecommendedHomePage),
      const Offset(0, -300),
      1200,
    );
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, find.byType(RecommendedHomePage)), 0);
    expect(_path(router), '/recommended');
  });

  // The tabs take a swipe up to 40° off horizontal once it has moved the
  // device slop sideways; a steeper one scrolls the feed. A 35° swipe went
  // to the feed while the tabs waited for twice the slop.
  for (final (degrees, switches) in [(35.0, true), (50.0, false)]) {
    testWidgets('a swipe ${degrees.round()}° off horizontal '
        '${switches ? 'moves the tabs' : 'leaves the tabs'}', (tester) async {
      final controller = await _pumpTabs(
        tester,
        length: 2,
        child: ListView(
          children: [for (var i = 0; i < 30; i++) const SizedBox(height: 80)],
        ),
      );
      setDeviceTouchSlop(tester);
      await tester.pump();

      final gesture = await dragLeftUp(
        tester,
        tester.getCenter(find.byType(ListView)),
        degrees: degrees,
      );
      final moved = controller.offset > 0;
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moved, switches);
    });
  }

  // The settle leaves at the finger's speed: a fling lands without slowing
  // first, a short drag turns round from its own momentum.
  for (final (name, dx, landsOn) in [
    ('a fling lands on the next tab', -120.0, 1),
    ('a short drag springs back', -60.0, 0),
  ]) {
    testWidgets('$name from the finger\'s speed', (tester) async {
      final controller = await _pumpTabs(tester, length: 3);
      setDeviceTouchSlop(tester);
      const seconds = 0.2;
      await tester.timedDrag(
        find.byType(TabSwipeSwitcher),
        Offset(dx, 0),
        const Duration(milliseconds: 200),
      );
      final width = tester.getSize(find.byType(TabSwipeSwitcher)).width;
      final fingerSpeed = -dx / width / seconds;
      await tester.pump();
      final released = controller.animation!.value;
      await tester.pump(const Duration(microseconds: 100));
      final speed = (controller.animation!.value - released) / 0.0001;
      expect(speed, closeTo(fingerSpeed, fingerSpeed * 0.15));
      // Landed once the motion is under half a pixel, not after a tail of
      // sub-pixel motion that held the index and the bar back.
      await tester.pump(const Duration(milliseconds: 400));
      expect((controller.index, controller.offset), (landsOn, 0.0));
    });
  }

  // Without a fling a release lands on the nearer tab, as PageView does; a
  // quarter of the screen used to switch.
  for (final (name, dx, landsOn) in [
    ('short of halfway springs back', -160.0, 0),
    ('past halfway switches', -260.0, 1),
  ]) {
    testWidgets('a slow drag $name', (tester) async {
      await _pumpHome(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(RecommendedHomePage)),
      );
      for (var moved = 0.0; moved > dx; moved -= 10) {
        await gesture.moveBy(const Offset(-10, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_tabIndex(tester, find.byType(RecommendedHomePage)), landsOn);
    });
  }

  testWidgets('the index waits for the landing', (tester) async {
    final controller = await _pumpTabs(tester, length: 3);
    final changes = <int>[];
    controller.addListener(() => changes.add(controller.index));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabSwipeSwitcher)),
    );
    for (var i = 0; i < 25; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    final (midway, changedMidway) = (controller.animation!.value, [...changes]);
    await gesture.up();
    await tester.pumpAndSettle();
    // Past halfway with the finger down: the page, the top bar and the
    // route still belonged to the first tab.
    expect(midway, greaterThan(0.5));
    expect(changedMidway, isEmpty);
    expect(controller.index, 1);
    expect(changes.toSet(), {1});
  });

  testWidgets('past the first tab the body pulls on a rubber band', (
    tester,
  ) async {
    const body = Key('body');
    final controller = await _pumpTabs(
      tester,
      length: 2,
      child: const SizedBox.expand(key: body),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(body)),
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    final (pulled, tabs) = (
      tester.getTopLeft(find.byKey(body)).dx,
      controller.animation!.value,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    // It followed the finger by less than the finger moved; the tabs stayed.
    expect(pulled, inExclusiveRange(10, 100));
    expect(tabs, 0);
    expect(tester.getTopLeft(find.byKey(body)).dx, 0);
  });

  testWidgets('a new tab list drops the spring-back of the old one', (
    tester,
  ) async {
    const vsync = TestVSync();
    final long = TabController(length: 4, vsync: vsync, initialIndex: 3);
    final short = TabController(length: 3, vsync: vsync, initialIndex: 1);
    final current = ValueNotifier(long);
    addTearDown(long.dispose);
    addTearDown(short.dispose);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: current,
          builder: (context, controller, _) => TabSwipeSwitcher(
            tabController: controller,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    // A short drag springs back to the last tab; the list shrinks mid-way.
    await tester.drag(
      find.byType(TabSwipeSwitcher),
      const Offset(40, 0),
      touchSlopX: 18,
    );
    await tester.pump(const Duration(milliseconds: 16));
    current.value = short;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((short.index, short.offset), (1, 0.0));
  });

  testWidgets('the tabs either side build one per still frame, next first', (
    tester,
  ) async {
    final prepared = await _pumpPreparing(tester, stalledImageWorker());
    expect(prepared, [2], reason: 'after the first frame, not in it');
    await tester.pump();
    expect(prepared, [2, 0]);
    await tester.pumpAndSettle();
    expect(prepared, [2, 0]);
  });

  testWidgets('a loading image and a held finger hold the tabs back', (
    tester,
  ) async {
    final start = Completer<ImageWorkerClient>();
    final worker = ImageWorker(
      start: (_, _) => start.future,
      config: () async => testImageWorkerConfig,
    );
    final load = worker.fetch(
      'https://i.pximg.net/a.jpg',
      priority: ImageFetchPriority.foreground,
    );
    final prepared = await _pumpPreparing(tester, worker);
    final finger = await tester.startGesture(const Offset(10, 10));
    start.completeError(StateError('no worker'));
    await expectLater(load, throwsA(isA<ImageWorkerUnavailable>()));
    expect(worker.foregroundLoads.value, 0, reason: 'a failure counts');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(prepared, isEmpty);

    await finger.up();
    await tester.pump();
    expect(prepared, [2]);
  });
}
