import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/motion/page_transitions.dart';

/// Marker layer used to tell a live subtree from a captured texture: while
/// [RoutePopSnapshot] paints its child, the child's composited layer chain
/// (inner RepaintBoundary → probe container → marker) sits in the scene and
/// the marker shows up in [WidgetTester.layers]. Once a texture is drawn the
/// boundary is never composited, so the marker leaves the layer tree — even
/// though the subtree stays mounted.
class _MarkerLayer extends ContainerLayer {}

class _MarkerProbe extends LeafRenderObjectWidget {
  const _MarkerProbe();

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMarkerProbe();
}

class _RenderMarkerProbe extends RenderBox {
  final _marker = _MarkerLayer();

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    context.addLayer(_marker);
  }
}

void main() {
  Future<({AnimationController animation, AnimationController secondary})>
  pumpSnapshot(WidgetTester tester) async {
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    final secondary = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(() {
      animation.dispose();
      secondary.dispose();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RoutePopSnapshot(
          animation: animation,
          secondaryAnimation: secondary,
          child: const _MarkerProbe(),
        ),
      ),
    );
    return (animation: animation, secondary: secondary);
  }

  /// Pumps [frames] mid-transition frames. The 300ms controllers tick from
  /// their first pumped frame, so each of these lands inside the transition.
  Future<void> pumpMidTransition(WidgetTester tester, [int frames = 4]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  bool pageIsLive(WidgetTester tester) =>
      tester.layers.any((layer) => layer is _MarkerLayer);

  bool snapshotting(WidgetTester tester) => tester
      .widget<SnapshotWidget>(find.byType(SnapshotWidget))
      .controller
      .allowSnapshotting;

  testWidgets('RoutePopSnapshot keeps an entering page live', (tester) async {
    final controllers = await pumpSnapshot(tester);

    controllers.animation.forward();
    await pumpMidTransition(tester);
    expect(pageIsLive(tester), isTrue);
    expect(snapshotting(tester), isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('RoutePopSnapshot keeps a covered page live', (tester) async {
    final controllers = await pumpSnapshot(tester);

    controllers.secondary.forward();
    await pumpMidTransition(tester);
    expect(pageIsLive(tester), isTrue);
    expect(snapshotting(tester), isFalse);
    await tester.pumpAndSettle();

    // Let the press window elapse so later tests leave no pending timer.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('RoutePopSnapshot freezes an exiting page into a texture', (
    tester,
  ) async {
    final controllers = await pumpSnapshot(tester);
    controllers.animation.value = 1;
    await tester.pump();

    controllers.animation.reverse();
    // The first reverse frame still paints live: the deferred capture is what
    // lets a Hero shuttle replace its source before the texture is taken.
    await tester.pump();
    expect(pageIsLive(tester), isTrue);
    expect(snapshotting(tester), isTrue);

    await pumpMidTransition(tester);
    expect(pageIsLive(tester), isFalse);
    expect(snapshotting(tester), isTrue);
    // Settle completes the pop; the released snapshot paints live again.
    await tester.pumpAndSettle();
  });

  testWidgets('RoutePopSnapshot replays a fresh texture for a settled reveal', (
    tester,
  ) async {
    final controllers = await pumpSnapshot(tester);

    // Cover, then let both the cover and the press-settle window finish.
    controllers.secondary.forward();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // The reveal captures the page's current state once, then blits it.
    controllers.secondary.reverse();
    await tester.pump();
    await pumpMidTransition(tester);
    expect(pageIsLive(tester), isFalse);
    expect(snapshotting(tester), isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('a reveal inside the press window keeps the page live', (
    tester,
  ) async {
    final controllers = await pumpSnapshot(tester);

    controllers.secondary.forward();
    await tester.pump(const Duration(milliseconds: 100));
    controllers.secondary.reverse();

    await pumpMidTransition(tester);
    expect(pageIsLive(tester), isTrue);
    expect(snapshotting(tester), isFalse);
    await tester.pumpAndSettle();
    // Let the pending press-settle timer fire before the test ends.
    await tester.pump(const Duration(milliseconds: 400));
  });
}
