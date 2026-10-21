import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/scroll_behavior.dart';

import 'helpers/localized_app.dart';

Future<ScrollController> _pumpList(
  WidgetTester tester, {
  bool inRefreshList = false,
}) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  Widget list = ListView.builder(
    controller: controller,
    itemCount: 60,
    itemBuilder: (_, index) => SizedBox(height: 80, child: Text('$index')),
  );
  if (inRefreshList) {
    list = PullToRefresh(onRefresh: () async {}, child: list);
  }
  await tester.pumpWidget(
    localizedApp(
      scrollBehavior: const FuncScrollBehavior(),
      home: Scaffold(body: list),
    ),
  );
  return controller;
}

void main() {
  testWidgets('a fling stops at the end instead of springing back', (
    tester,
  ) async {
    final controller = await _pumpList(tester);
    final max = controller.position.maxScrollExtent;
    controller.jumpTo(max - 400);
    await tester.fling(find.byType(ListView), const Offset(0, -300), 4000);
    var furthest = controller.offset;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (controller.offset > furthest) furthest = controller.offset;
    }
    expect(furthest, max);
    await tester.pumpAndSettle();
    expect(controller.offset, max);
  });

  testWidgets('a drag stops at either end', (tester) async {
    final controller = await _pumpList(tester);
    final max = controller.position.maxScrollExtent;
    for (final (start, pull) in [(max, -40.0), (0.0, 40.0)]) {
      controller.jumpTo(start);
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(Offset(0, pull));
      await gesture.moveBy(Offset(0, pull * 2));
      await tester.pump();
      expect(controller.offset, start);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, start);
    }
  });

  // Android's OverScroller: a fling at 1500px/s coasts about 390px and
  // stops in 0.6s, where iOS's friction rolls on for 5s.
  for (final inRefreshList in [false, true]) {
    testWidgets('a fling coasts on the Android curve'
        '${inRefreshList ? ' (refresh list)' : ''}', (tester) async {
      final controller = await _pumpList(tester, inRefreshList: inRefreshList);
      // iOS starts a fling at twice the speed and adds a fling's speed to
      // the next one.
      final physics = controller.position.physics;
      expect(physics.minFlingVelocity, kMinFlingVelocity);
      expect(physics.carriedMomentum(1500), 0);
      controller.jumpTo(1000);
      await tester.fling(find.byType(ListView), const Offset(0, -100), 1500);
      final released = controller.offset;
      final position = controller.position;
      var elapsed = Duration.zero;
      while (position.isScrollingNotifier.value) {
        await tester.pump(const Duration(milliseconds: 16));
        elapsed += const Duration(milliseconds: 16);
      }
      expect(elapsed, lessThan(const Duration(milliseconds: 800)));
      expect(controller.offset - released, inInclusiveRange(250, 550));
    });
  }

  testWidgets('a mouse brings a scrollbar and keeps the list as it was', (
    tester,
  ) async {
    final controller = await _pumpList(tester);
    controller.jumpTo(800);
    await tester.pump();
    final row = tester.element(find.text('12'));
    expect(find.byType(Scrollbar), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await tester.pump();
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(tester.element(find.text('12')), same(row));
    expect(controller.offset, 800);

    await mouse.removePointer();
    await tester.pump();
    expect(find.byType(Scrollbar), findsNothing);
  });

  // A text control's own scrollable inherits the page's physics; always
  // scrollable, a one-line title followed the finger instead of the page.
  for (final inRefreshList in [false, true]) {
    testWidgets('a selectable title that fits scrolls the page, not itself'
        '${inRefreshList ? ' (refresh list)' : ''}', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      const title = Key('title');
      Widget list = ListView(
        controller: controller,
        children: [
          const SelectableText('illust 1000', key: title),
          for (var i = 0; i < 30; i++) SizedBox(height: 80, child: Text('$i')),
        ],
      );
      if (inRefreshList) {
        list = PullToRefresh(onRefresh: () async {}, child: list);
      }
      await tester.pumpWidget(
        localizedApp(
          scrollBehavior: const FuncScrollBehavior(),
          home: Scaffold(body: list),
        ),
      );

      final titleScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(title),
          matching: find.byType(Scrollable),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(title)),
      );
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(titleScroll.position.pixels, 0, reason: 'the title kept still');
      expect(controller.offset, greaterThan(0), reason: 'the page scrolled');
      await gesture.up();
      await tester.pumpAndSettle();
    });
  }

  // Bouncing physics (iOS) hold back the move that crosses the slop and
  // ease in from 1.17px; Android lists follow the finger at once.
  for (final inRefreshList in [false, true]) {
    testWidgets('the list follows the finger from the move past the slop'
        '${inRefreshList ? ' (refresh list)' : ''}', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      Widget list = ListView.builder(
        controller: controller,
        itemCount: 60,
        itemBuilder: (_, index) => SizedBox(height: 80, child: Text('$index')),
      );
      if (inRefreshList) {
        list = PullToRefresh(onRefresh: () async {}, child: list);
      }
      await tester.pumpWidget(
        localizedApp(
          scrollBehavior: const FuncScrollBehavior(),
          home: Scaffold(body: list),
        ),
      );
      controller.jumpTo(800);

      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(0, -(kTouchSlop + 1)));
      await tester.pump();
      expect(controller.offset, 800 + kTouchSlop + 1);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  }

  // A slow swipe past half and a short flick each land their page and end
  // the scroll in about 300 ms; the framework's spring took about 0.7 s.
  for (final (name, dx, ms) in [
    ('a slow swipe', -220.0, 400),
    ('a flick', -60.0, 60),
  ]) {
    testWidgets('$name ends its page snap in about 300 ms', (tester) async {
      // A phone: 390 dp wide at 3x, which sets the snap's tolerance.
      tester.view
        ..physicalSize = const Size(1170, 2532)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final controller = PageController();
      addTearDown(controller.dispose);
      var ended = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NotificationListener<ScrollEndNotification>(
            onNotification: (_) => ended = true,
            child: PageView(
              controller: controller,
              physics: const PageSnapPhysics(),
              children: [for (var i = 0; i < 3; i++) Text('$i')],
            ),
          ),
        ),
      );
      await tester.timedDrag(
        find.byType(PageView),
        Offset(dx, 0),
        Duration(milliseconds: ms),
      );
      var frames = 0;
      while (!ended && frames < 60) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
      }
      expect(frames * 16, lessThanOrEqualTo(350));
      expect(controller.page, 1);
    });
  }
}
