import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/detail_world.dart';
import 'package:parfait/app/motion/hero_rect_clip.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

void main() {
  // The real router on the feed, then the detail page of the work in [json]
  // pushed with the feed's hero scope.
  Future<void> pushFromFeed(
    WidgetTester tester,
    Map<String, dynamic> json,
  ) async {
    setViewSize(tester, const Size(390, 844));
    // Detail pages embed VisibilityDetector trackers — zero interval uses
    // post-frame callbacks instead of a periodic timer.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final (container, _, _) = await makeWorld();
    final entity = parseIllust(json);
    container.read(illustStoreProvider).mergeAll([entity]);
    final router = pixivRouter('/recommended');
    await tester.pumpWidget(localizedRouterApp(router, container: container));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    unawaited(
      router.push<void>(
        '/recommended/illust/${entity.id}',
        extra: IllustRouteExtra(entity: entity, heroScope: 'feed'),
      ),
    );
    await tester.pump();
  }

  testWidgets('drag-to-dismiss returns to origin when canceled', (
    tester,
  ) async {
    const key = Key('drag-surface');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DragToDismiss(
            onDismissed: _noop,
            child: SizedBox(key: key, width: 200, height: 200),
          ),
        ),
      ),
    );
    await tester.pump();

    final surface = find.byKey(key);
    final origin = tester.getTopLeft(surface).dy;
    await tester.drag(find.byType(DragToDismiss), const Offset(0, 80));
    await tester.pump();
    expect(tester.getTopLeft(surface).dy, greaterThan(origin));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(surface).dy, closeTo(origin, 0.001));
  });

  testWidgets('feed → detail → viewer keeps one hero tag family', (
    tester,
  ) async {
    // The spatial contract: one illustHeroTag(scope, id) base flows feed
    // card → detail page-0 → viewer page-0; only the page suffix differs.
    // Asserted through the real route glue (openIllust / openImageViewer /
    // heroTagForPage), so a second tag family or a lost scope fails here.
    await mockNetworkImagesFor(() async {
      await pushFromFeed(
        tester,
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final baseTag = illustHeroTag('feed', 42);

      expect(find.byType(IllustDetailPage), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Hero && w.tag == baseTag),
        findsOneWidget,
        reason: 'detail page-0 must fly with the feed card tag',
      );

      // Tap the page image → the viewer continues the same tag base.
      await tester.tap(find.byType(DetailPageImage).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byType(ImageViewerPage), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is Hero && w.tag == baseTag),
        findsOneWidget,
        reason: 'viewer page-0 continues the same spatial chain',
      );
      // Page 1 derives from the same base — no second family appears.
      expect(
        find.byWidgetPredicate((w) => w is Hero && w.tag == '$baseTag-1'),
        findsNothing,
        reason: 'other pages mount only inside the pager when visited',
      );
    });
  });

  testWidgets('only the entry page flies back; a drag from another page '
      'slides away, back leaves like any page', (tester) async {
    await mockNetworkImagesFor(() async {
      await pushFromFeed(
        tester,
        illustJson(42, pageCount: 2, type: 'manga', withMetaPages: true),
      );
      await tester.pumpAndSettle();
      final baseTag = illustHeroTag('feed', 42);
      final viewer = find.byType(ImageViewerPage);
      double slide() => tester
          .widget<FractionalTranslation>(
            find
                .descendant(
                  of: viewer,
                  matching: find.byType(FractionalTranslation),
                )
                .first,
          )
          .translation
          .dy;

      // Leaving from page 2, where the viewer did not open: it carries no
      // Hero. Back plays the page transition; a drag slides the stage down.
      for (final drag in [false, true]) {
        await tester.tap(find.byType(DetailPageImage).first);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: viewer,
            matching: find.byWidgetPredicate(
              (w) => w is Hero && w.tag == baseTag,
            ),
          ),
          findsOneWidget,
          reason: 'the viewer opened on page 1 carries its Hero',
        );
        await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        expect(
          find.descendant(
            of: viewer,
            matching: find.byWidgetPredicate(
              (w) => w is Hero && '${w.tag}'.startsWith(baseTag),
            ),
          ),
          findsNothing,
        );

        if (drag) {
          await tester.drag(find.byType(DragToDismiss), const Offset(0, 300));
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(slide(), drag ? greaterThan(0) : 0, reason: 'drag: $drag');
        await tester.pumpAndSettle();
        expect(viewer, findsNothing);
      }
    });
  });

  testWidgets(
    'the viewer leaves whole and square; the detail page answers mid-flight',
    (tester) async {
      await mockNetworkImagesFor(() async {
        await pushFromFeed(tester, illustJson(42));
        await tester.pumpAndSettle();
        final detail = find.byType(IllustDetailPage);
        await tester.tap(find.byType(DetailPageImage).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(HeroRectClip), findsOneWidget, reason: 'in flight');
        // The stage fades out whole: no hole where the image sat. The image
        // flies square: neither end is a card.
        expect(
          tester.layers.whereType<ClipPathLayer>().where(
            (layer) => layer.clipPath!.fillType == PathFillType.evenOdd,
          ),
          isEmpty,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is HeroRectClip && w.child is ClipRRect,
          ),
          findsNothing,
        );
        // The detail page below stays live rather than a frozen texture, and
        // a tap on its image opens the viewer again.
        expect(
          tester
              .widgetList<SnapshotWidget>(
                find.ancestor(
                  of: detail,
                  matching: find.byType(SnapshotWidget),
                ),
              )
              .where((snapshot) => snapshot.controller.allowSnapshotting),
          isEmpty,
        );
        await tester.tap(find.byType(DetailPageImage).first);
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsOneWidget);
      });
    },
  );

  testWidgets('a cropped image covers the flight rect throughout', (
    tester,
  ) async {
    setViewSize(tester, const Size(390, 844));
    // A 1:5 work whose feed card shows its top in a 1:2 box, and a 2:1 one
    // whose square cover shows its middle; the detail page shows either
    // whole at full width.
    for (final (aspect, card) in [
      (0.2, const Size(180, 360)),
      (2.0, const Size(88, 88)),
    ]) {
      final tag = illustHeroTag('feed', 7);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(aspect),
          navigatorKey: navigatorKey,
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: card,
              child: Hero(
                tag: tag,
                flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                child: IllustHeroCardFrame(
                  cropAspect: aspect,
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      );
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 390,
                height: 390 / aspect,
                child: Hero(
                  tag: tag,
                  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                  child: const ColoredBox(
                    key: ValueKey('art'),
                    color: Colors.blue,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (final ms in [80, 80, 80]) {
        await tester.pump(Duration(milliseconds: ms));
        final shuttle = find.descendant(
          of: find.byType(HeroRectClip),
          matching: find.byKey(const ValueKey('art')),
        );
        final flight = tester.getRect(
          find.descendant(
            of: find.byType(HeroRectClip),
            matching: find.byType(CustomSingleChildLayout),
          ),
        );
        final image = tester.getRect(shuttle);
        // Never fitted inside the rect: that shrank it narrower mid-flight.
        final width = math.max(flight.width, flight.height * aspect);
        expect(image.width, closeTo(width, 0.5), reason: '$aspect');
        expect(image.height, closeTo(width / aspect, 0.5));
        expect(image.top, closeTo(flight.top, 0.5));
        expect(image.center.dx, closeTo(flight.center.dx, 0.5));
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets('mid-flight the detail endpoint paints no image of its own', (
    tester,
  ) async {
    // Audit F2: a faint full-size image seemed to sit at the landing spot
    // while the shuttle grew inside it. The landing Hero must stand in as an
    // empty placeholder, and the page must draw no second copy around it.
    setViewSize(tester, const Size(390, 844));
    VisibilityDetectorController.instance.updateInterval = Duration.zero;

    // A stale snapshot: the card says one page, the detail payload that
    // lands mid-flight says two. The image sliver must not change type
    // under the Hero.
    final (container, _, _) = await makeWorld();
    final entity = parseIllust(illustJson(42));
    container.read(illustStoreProvider).mergeAll([entity]);
    final navigatorKey = GlobalKey<NavigatorState>();

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        localizedApp(
          container: container,
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 150,
                height: 200,
                child: Hero(
                  tag: illustHeroTag('feed', 42),
                  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => IllustDetailPage(
              illustId: 42,
              initialEntity: entity,
              heroImageUrl: entity.imageUrls.medium,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(HeroRectClip), findsOneWidget, reason: 'in flight');
      final page = find.byType(DetailPageImage);
      expect(page, findsOneWidget);
      // The Hero keeps its child mounted but Offstage while it flies.
      bool painted(Element element) {
        var onstage = true;
        element.visitAncestorElements((ancestor) {
          final widget = ancestor.widget;
          if (widget is Offstage && widget.offstage) onstage = false;
          return onstage;
        });
        return onstage;
      }

      final artwork = find
          .descendant(
            of: find.byType(IllustDetailPage),
            matching: find.byWidgetPredicate(
              (w) => w is PixivImage && w.url == entity.imageUrls.medium,
            ),
          )
          .evaluate();
      expect(
        artwork.where(painted).map((element) => element.widget),
        isEmpty,
        reason: 'the page draws no copy of the artwork under the flight',
      );
      // The top bar and the action bar enter with the page, under the
      // flight, rather than after the image has landed.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(HeroRectClip), findsOneWidget, reason: 'in flight');
      double barEntrance() =>
          tester.widget<AppTopBar>(find.byType(AppTopBar)).entrance!.value;
      double actionBar() => tester
          .widget<DetailActionBar>(find.byType(DetailActionBar))
          .visibility
          .value;
      expect(barEntrance(), greaterThan(0));
      expect(actionBar(), greaterThan(0));
      await tester.pumpAndSettle();
      expect(barEntrance(), 1);
      expect(actionBar(), 1);
      expect(
        find.descendant(of: page, matching: find.byType(PixivImage)),
        findsOneWidget,
      );

      // Leaving, the action bar stays put and goes with the page; the
      // flight back is drawn above it.
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(actionBar(), 1);
      await tester.pumpAndSettle();
    });
  });

  testWidgets('Hero pop onto a user page matches its own chrome', (
    tester,
  ) async {
    setViewSize(tester, const Size(400, 800));

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      localizedApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    // The landing page: personal-page chrome — app bar (56) plus a pinned
    // TabBar row inside the scroll view (minExtent 56) — holding the Hero
    // source card, pushed so route.isFirst is false (no root bottom nav).
    navigatorKey.currentState!.push(
      _testPageRoute<void>(
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
                    child: _hero('user-page-hero', height: 300),
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
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(child: _hero('user-page-hero', width: 350, height: 500)),
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
    expect(find.byType(HeroRectClip), findsOneWidget);
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
    setViewSize(tester, const Size(400, 800));

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      localizedApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: ListView(
            children: [
              const SizedBox(height: 600),
              _hero('hero-test', height: 300),
            ],
          ),
          bottomNavigationBar: _bottomBar,
        ),
      ),
    );
    await tester.pump();

    navigatorKey.currentState!.push(
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(child: _hero('hero-test', width: 350, height: 500)),
          bottomNavigationBar: _bottomBar,
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
    expect(find.byType(HeroRectClip), findsOneWidget);
    expect(start.bottom, greaterThan(mid.bottom));
    expect(start.top, closeTo(mid.top, 0.001));
    expect(mid.top, closeTo(0, 0.001));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pump(const Duration(milliseconds: 100));
    final late = _heroPaintClipRect(tester)!;
    expect(late.bottom, lessThan(mid.bottom));
    await tester.pumpAndSettle();
  });

  testWidgets('Hero push from a nested feed stays intact', (tester) async {
    setViewSize(tester, const Size(400, 800));

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      localizedApp(
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
                    itemBuilder: (_, index) =>
                        _hero('nested-push-hero-test-$index', height: 600),
                    childCount: 2,
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: _bottomBar,
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
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Detail')),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: _hero(
                    'nested-push-hero-test-0',
                    width: 350,
                    height: 500,
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: _bottomBar,
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
    expect(find.byType(HeroRectClip), findsOneWidget);
    expect(early.top, greaterThan(mid.top));
    expect(early.bottom, closeTo(mid.bottom, 0.001));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pumpAndSettle();
  });
}

void _noop() {}

/// A red Hero flying with the production shuttle builder.
Hero _hero(Object tag, {double? width, double? height}) => Hero(
  tag: tag,
  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
  child: ColoredBox(
    color: Colors.red,
    child: SizedBox(width: width, height: height),
  ),
);

const _bottomBar = ColoredBox(color: Colors.blue, child: SizedBox(height: 100));

PageRoute<T> _testPageRoute<T>({required WidgetBuilder builder}) =>
    PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => builder(context),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: MotionTokens.pageCurve,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
      transitionDuration: MotionTokens.pageTransition,
      reverseTransitionDuration: MotionTokens.pageTransition,
    );

Rect _heroClipRect(WidgetTester tester) {
  final clip = tester.widget<Widget>(find.byType(HeroRectClip));
  return (clip as dynamic).globalRect as Rect;
}

Rect? _heroPaintClipRect(WidgetTester tester) {
  final render = tester.renderObject(find.byType(HeroRectClip));
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
