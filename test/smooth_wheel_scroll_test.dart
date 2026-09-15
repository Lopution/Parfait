import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixiv_func/app/widgets/smooth_wheel_scroll.dart';

void main() {
  Widget host(ScrollController controller) {
    return MaterialApp(
      home: Scaffold(
        body: SmoothWheelScroll(
          controller: controller,
          builder: (context, c, physics) => ListView.builder(
            controller: c,
            physics: physics,
            itemCount: 200,
            itemBuilder: (context, index) =>
                SizedBox(height: 40, child: Text('row $index')),
          ),
        ),
      ),
    );
  }

  Future<TestPointer> wheelDown(
    WidgetTester tester,
    double dy, {
    int device = 1,
  }) async {
    final pointer = TestPointer(device, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(200, 200)));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    return pointer;
  }

  testWidgets('mouse wheel drives the list to the tick target', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller));
    await tester.pump();

    await wheelDown(tester, 160);
    await tester.pump();
    // Driven animation, not the platform's fixed jump: the position is not
    // the tick target on the very next frame.
    expect(controller.offset, lessThan(160));

    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.offset, closeTo(160, 1));
  });

  testWidgets('repeated ticks accumulate past a single tick distance', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller));
    await tester.pump();

    for (var i = 0; i < 4; i++) {
      await wheelDown(tester, 160);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 600));
    // Four accumulated ticks must land well past one tick's distance.
    expect(controller.offset, greaterThan(160));
  });
}
