import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/pull_to_refresh.dart';

void main() {
  Widget buildSubject({required Future<void> Function() onRefresh}) {
    return MaterialApp(
      home: Scaffold(
        body: PullToRefresh(
          onRefresh: onRefresh,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: 40,
            itemBuilder: (_, index) =>
                SizedBox(height: 60, child: Text('item $index')),
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

  // Drag in steps rather than one big jump: bouncing physics computes friction
  // per update, so a single 300px move overscrolls far more than a real finger
  // travelling the same distance across many frames.
  Future<void> pullBy(
    WidgetTester tester,
    TestGesture gesture,
    int steps,
    double perStep,
  ) async {
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, perStep));
      await tester.pump();
    }
  }

  testWidgets('a reverse drag retracts the indicator and cancels', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await pullBy(tester, gesture, 10, 40);
    expect(indicator, findsOneWidget);
    final armed = tester.getCenter(indicator).dy;

    var previous = armed;
    var retracted = false;
    for (var step = 0; step < 16; step++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      if (indicator.evaluate().isEmpty) {
        retracted = true;
        break;
      }
      final current = tester.getCenter(indicator).dy;
      expect(
        current,
        lessThanOrEqualTo(previous),
        reason: 'reversing the drag must not push the indicator further down',
      );
      previous = current;
    }

    expect(
      retracted,
      isTrue,
      reason: 'a fully reversed pull must retract the indicator, not park it',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });

  testWidgets('reversing an armed pull retracts the indicator before the list '
      'scrolls', (tester) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    // Deliberately past the arm threshold: that is the path a real pull takes,
    // and it is the one where the framework's own spinner parks itself at two
    // thirds of its travel and rides up with the list.
    await pullBy(tester, gesture, 10, 40);
    expect(indicator, findsOneWidget);
    expect(
      scrollOffset(tester),
      lessThan(0),
      reason: 'the pull must be stored as overscroll, otherwise the reverse '
          'gesture has nothing to pay back before it can move the list',
    );

    var indicatorGone = false;
    for (var step = 0; step < 24; step++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();

      final onScreen =
          indicator.evaluate().isNotEmpty &&
          tester.getRect(indicator).bottom > 0;
      if (onScreen) {
        expect(
          scrollOffset(tester),
          lessThanOrEqualTo(0),
          reason: 'the list must not scroll while the indicator is still on '
              'screen — that is the "icon rides up with the list" defect',
        );
      } else {
        indicatorGone = true;
      }
    }

    expect(
      indicatorGone,
      isTrue,
      reason: 'the reverse drag must be long enough to retract the indicator, '
          'otherwise this test never reaches the half that matters',
    );
    expect(
      scrollOffset(tester),
      greaterThan(0),
      reason: 'once the indicator is gone the remaining gesture should scroll',
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
    await tester.fling(find.byType(ListView), const Offset(0, 80), 4000);
    var deepestOverscroll = 0.0;
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        indicator,
        findsNothing,
        reason: 'motion after the pointer lifts must not summon the indicator',
      );
      deepestOverscroll = deepestOverscroll < scrollOffset(tester)
          ? deepestOverscroll
          : scrollOffset(tester);
    }
    await tester.pumpAndSettle();

    expect(
      deepestOverscroll,
      lessThan(0),
      reason: 'the flick must actually overscroll past the leading edge, '
          'otherwise this test proves nothing',
    );
    expect(scrollOffset(tester), 0);
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });
}
