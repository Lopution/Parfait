import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/motion/page_transitions.dart';

class _PaintCounter extends LeafRenderObjectWidget {
  const _PaintCounter({required this.counter});

  final _Counter counter;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _CountingBox(counter);
}

class _Counter {
  int paints = 0;
}

class _CountingBox extends RenderBox {
  _CountingBox(this.counter);

  final _Counter counter;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    counter.paints++;
  }
}

void main() {
  testWidgets('RoutePopSnapshot freezes child during transition', (
    tester,
  ) async {
    final counter = _Counter();
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    final secondary = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RoutePopSnapshot(
          animation: animation,
          secondaryAnimation: secondary,
          child: _PaintCounter(counter: counter),
        ),
      ),
    );
    counter.paints = 0;

    animation.forward();
    // Ten frames over the 300ms transition.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    // A frozen page paints once when the snapshot is captured; a live page
    // paints every frame.
    // ignore: avoid_print
    print('CHILD PAINTS DURING TRANSITION: ${counter.paints}');
    expect(counter.paints, lessThan(4));
    animation.dispose();
    secondary.dispose();
  });
}
