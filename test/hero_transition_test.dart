import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:pixiv_func/app/replica_page_route.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';

void main() {
  testWidgets('Hero pop onto a user page matches its own chrome', (
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
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    // The landing page: personal-page chrome — app bar (56) plus a pinned
    // TabBar row inside the scroll view (minExtent 56) — holding the Hero
    // source card, pushed so route.isFirst is false (no root bottom nav).
    navigatorKey.currentState!.push(
      ReplicaPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('u')),
          body: NestedScrollView(
            headerSliverBuilder: (_, _) => [
              SliverPersistentHeader(
                pinned: true,
                delegate: _FixedHeaderDelegate(56),
              ),
            ],
            body: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(10),
                  sliver: SliverToBoxAdapter(
                    child: Hero(
                      tag: 'user-page-hero',
                      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                      child: const ColoredBox(
                        color: Colors.red,
                        child: SizedBox(height: 300),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Reproduce the real profile flow: the user can open a work after the
    // flexible header has started collapsing. The source Hero remains partly
    // visible, but its viewport clip is no longer the initial header bound.
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Hero && widget.tag == 'user-page-hero',
      ),
      findsOneWidget,
    );

    // Detail page on top; popping lands back on the user page above.
    navigatorKey.currentState!.push(
      ReplicaPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: Hero(
              tag: 'user-page-hero',
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 350, height: 500),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final start = _heroClipRect(tester);
    await tester.pump(const Duration(milliseconds: 150));
    final mid = _heroClipRect(tester);

    // The boundary moves from the detail route's content area to the
    // profile route's app bar + pinned TabBar boundary. A static clip would
    // hard-cut the image as reported on device.
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
      findsOneWidget,
    );
    expect(start.top, lessThan(mid.top));
    expect(start.bottom, greaterThanOrEqualTo(mid.bottom));
    expect(mid.top, greaterThan(0));
    expect(mid.bottom, closeTo(800, 0.001));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pump(const Duration(milliseconds: 100));
    final late = _heroPaintClipRect(tester)!;
    expect(late.top, greaterThan(mid.top));
    expect(late.bottom, closeTo(800, 0.001));
    await tester.pumpAndSettle();
  });

  testWidgets('Hero pop flight is occluded by the chrome', (tester) async {
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
    await tester.pump(const Duration(milliseconds: 1));
    final start = _heroClipRect(tester);
    await tester.pump(const Duration(milliseconds: 150));
    final mid = _heroClipRect(tester);

    // The bottom boundary retracts continuously toward the landing page's
    // 100px bottom navigation. It must not jump to the final clip at mid-flight.
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
      findsOneWidget,
    );
    expect(start.bottom, greaterThan(mid.bottom));
    expect(start.top, closeTo(mid.top, 0.001));
    expect(mid.top, closeTo(0, 0.001));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pump(const Duration(milliseconds: 100));
    final late = _heroPaintClipRect(tester)!;
    expect(late.bottom, lessThan(mid.bottom));
    await tester.pumpAndSettle();
  });

  testWidgets('Hero pop from a nested pinned header moves with the chrome', (
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
          appBar: AppBar(title: const Text('Feed')),
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
    await tester.pump(const Duration(milliseconds: 1));
    final start = _heroClipRect(tester);
    await tester.pump(const Duration(milliseconds: 150));
    final mid = _heroClipRect(tester);

    // Both edges move toward the landing page's pinned-header and bottom-nav
    // boundaries. This is the regression case for a scrolled/nested profile.
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
      findsOneWidget,
    );
    expect(start.top, lessThan(mid.top));
    expect(start.bottom, greaterThan(mid.bottom));
    expect(mid.top, greaterThan(0));
    expect(mid.bottom, lessThan(800));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pump(const Duration(milliseconds: 100));
    final late = _heroPaintClipRect(tester)!;
    expect(late.top, greaterThan(mid.top));
    expect(late.bottom, lessThan(mid.bottom));
    await tester.pumpAndSettle();
  });

  testWidgets('Hero push from a nested feed stays intact', (tester) async {
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
                delegate: _FixedHeaderDelegate(300),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _FixedHeaderDelegate(56),
              ),
            ],
            body: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 10)),
                SliverPadding(
                  padding: const EdgeInsets.all(10),
                  sliver: SliverMasonryGrid.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 10,
                    itemBuilder: (_, index) => Hero(
                      tag: 'nested-push-hero-test-$index',
                      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                      child: const ColoredBox(
                        color: Colors.red,
                        child: SizedBox(height: 600),
                      ),
                    ),
                    childCount: 2,
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

    final sourceHero = find.byWidgetPredicate(
      (widget) => widget is Hero && widget.tag == 'nested-push-hero-test-0',
    );
    expect(
      tester.getTopLeft(sourceHero).dy,
      greaterThan(300),
      reason: 'the source artwork must start below the profile header',
    );

    navigatorKey.currentState!.push(
      ReplicaPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Detail')),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Hero(
                    tag: 'nested-push-hero-test-0',
                    flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                    child: const ColoredBox(
                      color: Colors.red,
                      child: SizedBox(width: 350, height: 500),
                    ),
                  ),
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
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final early = _heroClipRect(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final mid = _heroClipRect(tester);

    // Push uses the same moving boundary in the opposite direction: the
    // source profile/feed chrome releases its clipped portion progressively,
    // then the detail chrome becomes the active boundary.
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
      ),
      findsOneWidget,
    );
    expect(early.top, greaterThan(mid.top));
    expect(early.bottom, closeTo(mid.bottom, 0.001));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pumpAndSettle();
  });
}

Rect _heroClipRect(WidgetTester tester) {
  final clip = tester.widget<Widget>(
    find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
    ),
  );
  return (clip as dynamic).globalRect as Rect;
}

Rect? _heroPaintClipRect(WidgetTester tester) {
  final render = tester.renderObject(
    find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_GlobalRectClip',
    ),
  );
  return (render as dynamic).debugLastPaintClipRect as Rect?;
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
