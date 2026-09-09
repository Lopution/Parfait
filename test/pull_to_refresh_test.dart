import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/pull_to_refresh.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

void main() {
  Widget buildSubject({
    required Future<void> Function() onRefresh,
    List<ScrollNotification>? notifications,
  }) {
    Widget list = ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 40,
      itemBuilder: (_, index) =>
          SizedBox(height: 60, child: Text('item $index')),
    );
    if (notifications != null) {
      list = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          notifications.add(notification);
          return false;
        },
        child: list,
      );
    }
    return MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

      home: Scaffold(
        body: PullToRefresh(onRefresh: onRefresh, child: list),
      ),
    );
  }

  Widget buildNestedSubject({required Future<void> Function() onRefresh}) {
    return MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

      home: Scaffold(
        body: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            const SliverToBoxAdapter(child: SizedBox(height: 180)),
          ],
          body: PullToRefresh(
            isNested: true,
            onRefresh: onRefresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 41,
              itemBuilder: (_, index) {
                if (index == 0) return const HeaderLocator();
                return SizedBox(
                  height: 60,
                  child: Text('nested item ${index - 1}'),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  final indicator = find.byType(RefreshProgressIndicator);

  double scrollOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

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

    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });

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
    await pullBy(tester, gesture, 4, 30);
    expect(indicator, findsOneWidget);

    var previous = tester.getCenter(indicator).dy;
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
        reason: 'reversing the drag must retract the indicator',
      );
      previous = current;
    }

    expect(retracted, isTrue);
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
    // The open (non-clamping) header rides the overscroll: the list is
    // pulled down while the indicator appears. The pull is deliberately past
    // the arm threshold.
    await pullBy(tester, gesture, 10, 40);
    expect(indicator, findsOneWidget);
    expect(
      scrollOffset(tester),
      lessThan(0),
      reason: 'the list is pulled down while the indicator is open',
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
          lessThanOrEqualTo(0.001),
          reason:
              'while the indicator is visible the reverse gesture only '
              'retracts it / bounces the overscroll back, never scrolls up',
        );
      } else {
        indicatorGone = true;
      }
    }

    expect(indicatorGone, isTrue);
    expect(
      scrollOffset(tester),
      greaterThan(0),
      reason: 'the remaining reverse gesture should scroll after retraction',
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

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));

    expect(refreshCount, 1);
    expect(indicator, findsNothing);
  });

  testWidgets('ballistic overscroll after the pointer lifts starts no pull', (
    tester,
  ) async {
    var refreshCount = 0;
    final notifications = <ScrollNotification>[];
    await tester.pumpWidget(
      buildSubject(
        onRefresh: () async => refreshCount++,
        notifications: notifications,
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(scrollOffset(tester), greaterThan(0));
    notifications.clear();

    // The short, fast flick reaches the leading edge after the pointer is
    // gone. It must not turn that ballistic motion into a new pull.
    await tester.fling(find.byType(ListView), const Offset(0, 80), 4000);
    var sawLeadingEdgeActivity = false;
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        indicator,
        findsNothing,
        reason: 'post-release motion must not summon the indicator',
      );
      sawLeadingEdgeActivity =
          sawLeadingEdgeActivity ||
          notifications.any(
            (notification) =>
                notification is OverscrollNotification ||
                (notification is ScrollUpdateNotification &&
                    notification.metrics.extentBefore == 0),
          );
    }
    await tester.pumpAndSettle();

    expect(sawLeadingEdgeActivity, isTrue);
    expect(scrollOffset(tester), closeTo(0, 0.001));
    expect(refreshCount, 0);
    expect(indicator, findsNothing);
  });

  testWidgets('the shared wrapper uses the PixEz-style material header', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject(onRefresh: () async {}));
    await tester.pumpAndSettle();

    expect(find.byType(EasyRefresh), findsOneWidget);
  });

  testWidgets('the shared wrapper refreshes a nested scroll view once', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildNestedSubject(onRefresh: () async => refreshCount++),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));

    expect(refreshCount, 1);
    expect(indicator, findsNothing);
  });
}
