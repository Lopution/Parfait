import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/feed/load_more_listener.dart';
import 'package:parfait/app/widgets/smooth_wheel_scroll.dart';

void main() {
  Widget app(Widget body) => MaterialApp(home: Scaffold(body: body));

  Widget wheelList(
    ScrollController c,
    ScrollPhysics? p, {
    int count = 200,
    String prefix = 'row',
  }) => ListView.builder(
    controller: c,
    physics: p,
    itemCount: count,
    itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$prefix $i')),
  );

  Widget host(ScrollController controller) => app(
    SmoothWheelScroll(
      controller: controller,
      builder: (_, c, p) => wheelList(c, p),
    ),
  );

  Future<TestPointer> wheelDown(
    WidgetTester tester,
    double dy, {
    int device = 1,
  }) async {
    final pointer = TestPointer(device, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(200, 200)));
    await tester.pump();
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    return pointer;
  }

  testWidgets('the first touch on a desktop drags the list', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller));

    // A touchscreen never hovers, so nothing put the list in wheel mode.
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    expect(controller.offset, greaterThan(0));
  });

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

  testWidgets(
    'mouse hover does not freeze trackpad pan-zoom scrolling',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));
      await tester.pump();

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(200, 200)));
      await tester.pump();

      final trackpad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(
        trackpad.panZoomStart(const Offset(200, 200)),
      );
      await tester.sendEventToBinding(
        trackpad.panZoomUpdate(
          const Offset(200, 200),
          pan: const Offset(0, -140),
        ),
      );
      await tester.sendEventToBinding(trackpad.panZoomEnd());
      await tester.pump();

      expect(controller.offset, greaterThan(0));
    },
  );

  testWidgets(
    'falls back to PrimaryScrollController when controller is omitted',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final primary = ScrollController();
      addTearDown(primary.dispose);
      await tester.pumpWidget(
        app(
          PrimaryScrollController(
            controller: primary,
            child: SmoothWheelScroll(
              builder: (_, c, p) => wheelList(c, p, count: 120),
            ),
          ),
        ),
      );
      await tester.pump();
      await wheelDown(tester, 120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(primary.offset, closeTo(120, 1));
    },
  );

  testWidgets(
    'downward wheel tick at bottom edge notifies LoadMoreListener',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var loadMoreCalls = 0;
      await tester.pumpWidget(
        app(
          LoadMoreListener(
            itemCount: 150,
            onLoadMore: () => loadMoreCalls++,
            child: SmoothWheelScroll(
              controller: controller,
              builder: (_, c, p) => wheelList(c, p, count: 150),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(loadMoreCalls, 0);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      loadMoreCalls = 0;

      await wheelDown(tester, 120);
      await tester.pump();
      expect(loadMoreCalls, greaterThan(0));
    },
  );

  testWidgets(
    'ScrollAwareHoverRegion suppresses hover during active wheel scroll',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = ScrollController();
      final hovered = ValueNotifier<bool>(false);
      addTearDown(controller.dispose);
      addTearDown(hovered.dispose);
      await tester.pumpWidget(
        app(
          SmoothWheelScroll(
            controller: controller,
            builder: (_, c, p) => ListView.builder(
              controller: c,
              physics: p,
              itemCount: 100,
              itemBuilder: (_, i) => i == 0
                  ? ScrollAwareHoverRegion(
                      onHover: (v) => hovered.value = v,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: hovered,
                        builder: (_, v, _) => SizedBox(
                          height: 60,
                          child: Text('row 0 ${v ? "HOVER" : "IDLE"}'),
                        ),
                      ),
                    )
                  : SizedBox(height: 60, child: Text('row $i')),
            ),
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(100, 30)));
      await tester.pump();
      expect(find.text('row 0 HOVER'), findsOneWidget);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 20)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('row 0 IDLE'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('row 0 HOVER'), findsOneWidget);
    },
  );

  Future<void> settleWheel(WidgetTester tester, double dy) async {
    await wheelDown(tester, dy);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'interrupting wheel animation via trackpad or jump resets accumulator cleanly',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller));
      await tester.pump();

      await wheelDown(tester, 160);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      final trackpad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(
        trackpad.panZoomStart(const Offset(200, 200)),
      );
      await tester.sendEventToBinding(
        trackpad.panZoomUpdate(
          const Offset(200, 200),
          pan: const Offset(0, -320),
        ),
      );
      await tester.sendEventToBinding(trackpad.panZoomEnd());
      await tester.pump();
      final afterTrackpad = controller.offset;
      expect(afterTrackpad, greaterThan(280));

      await settleWheel(tester, 120);
      expect(controller.offset, closeTo(afterTrackpad + 120, 2));

      await wheelDown(tester, 120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      controller.jumpTo(700);
      await tester.pump();
      await settleWheel(tester, 100);
      expect(controller.offset, closeTo(800, 2));
    },
  );

  testWidgets(
    'nested inner SmoothWheelScroll yields to outer when short or at edge, and PageView still loads more',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final outer = ScrollController();
      final inner = ScrollController();
      final tabFeed = ScrollController();
      final innerCount = ValueNotifier<int>(2);
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      addTearDown(tabFeed.dispose);
      addTearDown(innerCount.dispose);
      await tester.pumpWidget(
        app(
          SmoothWheelScroll(
            controller: outer,
            builder: (_, oc, op) => ListView(
              controller: oc,
              physics: op,
              children: [
                SizedBox(
                  height: 200,
                  child: SmoothWheelScroll(
                    controller: inner,
                    builder: (_, ic, ip) => ValueListenableBuilder<int>(
                      valueListenable: innerCount,
                      builder: (_, n, _) =>
                          wheelList(ic, ip, count: n, prefix: 'in'),
                    ),
                  ),
                ),
                const SizedBox(height: 1600),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await settleWheel(tester, 140);
      expect(outer.offset, closeTo(140, 2));

      innerCount.value = 20;
      outer.jumpTo(0);
      await tester.pump();
      inner.jumpTo(inner.position.maxScrollExtent);
      await tester.pump();
      await settleWheel(tester, 120);
      expect(outer.offset, closeTo(120, 2));

      var loadMoreCalls = 0;
      await tester.pumpWidget(
        app(
          PageView(
            children: [
              LoadMoreListener(
                itemCount: 100,
                onLoadMore: () => loadMoreCalls++,
                child: SmoothWheelScroll(
                  controller: tabFeed,
                  builder: (_, c, p) =>
                      wheelList(c, p, count: 100, prefix: 't'),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      tabFeed.jumpTo(tabFeed.position.maxScrollExtent);
      await tester.pump();
      loadMoreCalls = 0;
      await wheelDown(tester, 120);
      await tester.pump();
      expect(loadMoreCalls, greaterThan(0));
    },
  );
}
