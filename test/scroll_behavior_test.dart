import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/scroll_behavior.dart';

import 'helpers/localized_app.dart';

Future<ScrollController> _pumpList(WidgetTester tester) async {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      scrollBehavior: const FuncScrollBehavior(),
      home: ListView.builder(
        controller: controller,
        itemCount: 60,
        itemBuilder: (_, index) => SizedBox(height: 80, child: Text('$index')),
      ),
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

  testWidgets('a drag still pulls past the end and springs back', (
    tester,
  ) async {
    final controller = await _pumpList(tester);
    final max = controller.position.maxScrollExtent;
    controller.jumpTo(max);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -40));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(controller.offset, greaterThan(max));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.offset, max);
  });

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
}
