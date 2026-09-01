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
            itemCount: 20,
            itemBuilder: (_, index) =>
                SizedBox(height: 60, child: Text('item $index')),
          ),
        ),
      ),
    );
  }

  testWidgets('reverse pull follows the finger before dismissing', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 320));
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    final beforeReverse = tester.getCenter(
      find.byType(RefreshProgressIndicator),
    );

    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    final afterFirstReverse = tester.getCenter(
      find.byType(RefreshProgressIndicator),
    );
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(afterFirstReverse.dy, lessThan(beforeReverse.dy));

    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    final afterSecondReverse = tester.getCenter(
      find.byType(RefreshProgressIndicator),
    );
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(afterSecondReverse.dy, lessThan(afterFirstReverse.dy));
    expect(
      afterFirstReverse.dy - afterSecondReverse.dy,
      closeTo(beforeReverse.dy - afterFirstReverse.dy, 0.5),
      reason: 'equal reverse drag deltas should move the indicator linearly',
    );

    await gesture.moveBy(const Offset(0, -240));
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(refreshCount, 0);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('a released armed pull still refreshes once', (tester) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildSubject(onRefresh: () async => refreshCount++),
    );
    await tester.pump();

    await tester.drag(find.byType(ListView), const Offset(0, 320));
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
  });
}
