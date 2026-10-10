import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/scroll_behavior.dart';

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
}
