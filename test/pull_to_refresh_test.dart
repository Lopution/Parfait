import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/pull_to_refresh.dart';

void main() {
  // Counts overscroll produced with no pointer down — the ballistic settle
  // that used to re-open the old wrapper's drag tracking.
  var pointerUpOverscrolls = 0;

  setUp(() => pointerUpOverscrolls = 0);

  Widget buildSubject({required Future<void> Function() onRefresh}) {
    return MaterialApp(
      home: Scaffold(
        body: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is OverscrollNotification &&
                notification.dragDetails == null) {
              pointerUpOverscrolls++;
            }
            return false;
          },
          child: PullToRefresh(
            onRefresh: onRefresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 40,
              itemBuilder: (_, index) =>
                  SizedBox(height: 60, child: Text('item $index')),
            ),
          ),
        ),
      ),
    );
  }

  final indicator = find.byType(RefreshProgressIndicator);

  double scrollOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  testWidgets('an outward pull follows the finger, then cancels below the '
      'threshold', (tester) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    var previous = double.negativeInfinity;
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(indicator, findsOneWidget);
      final current = tester.getCenter(indicator).dy;
      expect(
        current,
        greaterThan(previous),
        reason: 'the indicator should descend as the finger pulls down',
      );
      previous = current;
    }

    // 120px is short of the framework's arm threshold, so this release is a
    // cancel — and a cancel still has to leave nothing on screen.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });

  testWidgets('a reverse drag moves the indicator back and cancels', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    expect(indicator, findsOneWidget);
    final armed = tester.getCenter(indicator).dy;

    var previous = armed;
    for (var step = 0; step < 6; step++) {
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      // The indicator must stay on screen for the whole gesture: a pull that
      // vanishes mid-drag and a pull that survives release are the two halves
      // of the same defect.
      expect(indicator, findsOneWidget);
      final current = tester.getCenter(indicator).dy;
      expect(
        current,
        lessThanOrEqualTo(previous),
        reason: 'reversing the drag must not push the indicator further down',
      );
      previous = current;
    }
    expect(
      previous,
      lessThan(armed),
      reason: 'the indicator should have travelled back up with the finger',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });

  testWidgets('a released armed pull refreshes once and hides the indicator', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 320));
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
    expect(indicator, findsNothing);
  });

  testWidgets('ballistic overscroll after the pointer lifts starts no pull', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(scrollOffset(tester), greaterThan(0));

    // A short, fast flick: the drag itself never reaches the leading edge, so
    // everything that touches the edge happens after the finger is gone.
    pointerUpOverscrolls = 0;
    await tester.fling(find.byType(ListView), const Offset(0, 80), 4000);
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        indicator,
        findsNothing,
        reason: 'motion after the pointer lifts must not summon the indicator',
      );
    }
    await tester.pumpAndSettle();

    expect(
      pointerUpOverscrolls,
      greaterThan(0),
      reason: 'the flick must actually overscroll the leading edge, '
          'otherwise this test proves nothing',
    );
    expect(scrollOffset(tester), 0);
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });
}
