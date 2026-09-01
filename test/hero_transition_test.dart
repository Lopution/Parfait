import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/replica_page_route.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';

void main() {
  testWidgets('Hero pop stays inside the source viewport', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: ListView(
            children: [
              const SizedBox(height: 600),
              Hero(
                tag: 'hero-test',
                flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                child: const ColoredBox(
                  color: Colors.red,
                  child: SizedBox(height: 300),
                ),
              ),
            ],
          ),
          bottomNavigationBar: const ColoredBox(
            color: Colors.blue,
            child: SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    navigatorKey.currentState!.push(
      ReplicaPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: Hero(
              tag: 'hero-test',
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 350, height: 500),
              ),
            ),
          ),
          bottomNavigationBar: const ColoredBox(
            color: Colors.blue,
            child: SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
      findsOneWidget,
    );

    final clip = tester.widget<Widget>(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
    );
    expect(
      (clip as dynamic).globalRect,
      const Rect.fromLTRB(0, 0, 400, 700),
      reason: 'the pop shuttle keeps the source viewport intersection',
    );
  });

  testWidgets('Hero pop respects a nested pinned-header overlap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (_, _) => [
              SliverPersistentHeader(
                pinned: true,
                delegate: _FixedHeaderDelegate(80),
              ),
            ],
            body: ListView(
              children: [
                Hero(
                  tag: 'nested-hero-test',
                  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                  child: const ColoredBox(
                    color: Colors.red,
                    child: SizedBox(height: 300),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: const ColoredBox(
            color: Colors.blue,
            child: SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    navigatorKey.currentState!.push(
      ReplicaPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: Hero(
              tag: 'nested-hero-test',
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 350, height: 500),
              ),
            ),
          ),
          bottomNavigationBar: const ColoredBox(
            color: Colors.blue,
            child: SizedBox(height: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final clip = tester.widget<Widget>(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
    );
    final rect = (clip as dynamic).globalRect as Rect;
    expect(rect.top, closeTo(80, 0.1));
    expect(rect.bottom, closeTo(700, 0.1));
  });
}

class _FixedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _FixedHeaderDelegate(this.extent);

  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => const SizedBox.expand(child: ColoredBox(color: Colors.green));

  @override
  bool shouldRebuild(covariant _FixedHeaderDelegate oldDelegate) => false;
}
