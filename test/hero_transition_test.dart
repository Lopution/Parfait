import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:http/http.dart' as http;
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/core/debug/hero_anomaly_log.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/detail_world.dart';
import 'package:parfait/app/motion/hero_rect_clip.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/test_preferences.dart';
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

  // A root page (the viewer) pairs its Hero with the top page of every
  // branch: the same work open in a branch out of sight shared the tag,
  // and the image flew to where that branch had it.
  testWidgets('the viewer pairs only with the branch on screen', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      setViewSize(tester, const Size(390, 844));
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final (container, _, _) = await makeWorld();
      final entity = parseIllust(illustJson(42));
      container.read(illustStoreProvider).mergeAll([entity]);
      final router = pixivRouter('/settings');
      await tester.pumpWidget(localizedRouterApp(router, container: container));
      await tester.pump();
      for (final branch in ['/settings', '/recommended']) {
        router.go(branch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        unawaited(
          router.push<void>(
            '$branch/illust/42',
            extra: IllustRouteExtra(entity: entity, heroScope: 'feed'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.tap(find.byType(DetailPageImage).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: 'one Hero per tag');
      expect(find.byType(HeroRectClip), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsOneWidget);
    });
  });

  // The flight self-check: a card end the user cannot see is logged and
  // announced; a flight between two live ends on screen is not.
  testWidgets('a flight from a card out of sight is logged, others not', (
    tester,
  ) async {
    installMemoryPreferences();
    final navigator = GlobalKey<NavigatorState>();
    var live = true;
    late StateSetter setLive;
    const tag = 'IllustHero:feed:7';
    Widget hero(double size) => Hero(
      tag: tag,
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: IllustHeroCardFrame(child: SizedBox.square(dimension: size)),
    );
    await tester.pumpWidget(
      localizedApp(
        overrides: const [],
        navigatorKey: navigator,
        builder: promptHostBuilder,
        home: StatefulBuilder(
          builder: (context, setState) {
            setLive = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: TickerMode(enabled: live, child: hero(100)),
            );
          },
        ),
      ),
    );
    final log = HeroAnomalyLog(SharedPreferencesAsync());
    Future<void> openAndClose() async {
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => Center(child: hero(300))),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
    }

    await openAndClose();
    expect(await tester.runAsync(log.read), isEmpty);
    expect(find.text('已记录一次 Hero 异常'), findsNothing);

    setLive(() => live = false);
    await tester.pump();
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => Center(child: hero(300))),
      ),
    );
    await tester.pump();
    await tester.pump();
    final entries = (await tester.runAsync(log.read))!;
    expect(entries, hasLength(1));
    expect(entries.single, contains('push $tag'));
    expect(entries.single, contains('card end still'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已记录一次 Hero 异常'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
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
        int? decodeWidthIn(Finder scope) => tester
            .widget<PixivImage>(
              find.descendant(of: scope, matching: find.byType(PixivImage)),
            )
            .memCacheWidth;
        final shown = decodeWidthIn(find.byType(ImageViewerPage));
        expect(shown, isNotNull, reason: 'the viewer shows its preview');
        await tester.tap(find.byType(BackButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(HeroRectClip), findsOneWidget, reason: 'in flight');
        // The shuttle paints the decode the viewer showed: no second decode.
        expect(decodeWidthIn(find.byType(HeroRectClip)), shown);
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

  testWidgets('a cropped image covers its flight rect; both sides keep pace', (
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
                createRectTween: illustHeroRectTween,
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
                  createRectTween: illustHeroRectTween,
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
      var width0 = 0.0;
      // The screen cuts the long work's box short.
      final detailHeight = math.min(390 / aspect, 844.0);
      for (final ms in [80, 80, 80]) {
        await tester.pump(Duration(milliseconds: ms));
        Finder inFlight(Finder finder) =>
            find.descendant(of: find.byType(HeroRectClip), matching: finder);
        final flight = tester.getRect(
          inFlight(find.byType(CustomSingleChildLayout)),
        );
        final image = tester.getRect(
          inFlight(find.byKey(const ValueKey('art'))).first,
        );
        // Never fitted inside the rect: that shrank it narrower mid-flight.
        final width = math.max(flight.width, flight.height * aspect);
        expect(image.width, closeTo(width, 0.5), reason: '$aspect');
        expect(image.height, closeTo(width / aspect, 0.5));
        expect(image.top, closeTo(flight.top, 0.5));
        expect(image.center.dx, closeTo(flight.center.dx, 0.5));
        // Shown like an uncropped card's image: whole, cut to the rect,
        // nothing faded past it.
        final cut = find
            .ancestor(
              of: find.byType(CustomSingleChildLayout).last,
              matching: find.byType(ClipRRect),
            )
            .first;
        expect(tester.getRect(cut), flight);
        expect(inFlight(find.byType(Opacity)), findsNothing);
        expect(flight.width, greaterThan(width0));
        width0 = flight.width;
        // Both sides by one progress: Material's corner arcs had the square
        // cover reach its width, then shrink a step more in height.
        expect(
          (flight.width - card.width) / (390 - card.width),
          closeTo(
            (flight.height - card.height) / (detailHeight - card.height),
            0.01,
          ),
        );
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'a top-square card flies its square alone; the work fades in once decoded',
    (tester) async {
      setViewSize(tester, const Size(390, 844));
      const square =
          'https://i.pximg.net/c/540x540_70/img-master/img/7_p0_square1200.jpg';
      final entity = parseIllust(illustJson(7, width: 400, height: 2000));
      final large = entity.imageUrls.large;
      // The card's square answers at once; the work's file when the test
      // sends it.
      final client = HeldBodyClient(
        respond: (request) => '${request.url}' == square
            ? http.StreamedResponse(
                Stream.value(onePixelPng),
                200,
                request: request,
              )
            : null,
      );
      final (container, _, _) = await makeWorld(
        extraOverrides: [
          imageWorkerProvider.overrideWithValue(
            inProcessImageWorker(() => client),
          ),
        ],
      );
      final tag = illustHeroTag('feed', 7);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        localizedApp(
          container: container,
          navigatorKey: navigatorKey,
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.square(
              dimension: 180,
              child: Hero(
                tag: tag,
                createRectTween: illustHeroRectTween,
                flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                child: IllustHeroCardFrame(
                  cropAspect: entity.pageAspectRatioAt(0),
                  topSquare: true,
                  child: const ColoredBox(
                    key: ValueKey('card'),
                    color: Colors.red,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      unawaited(
        navigatorKey.currentState!.push(
          FuncPage<void>(
            sharedElement: true,
            child: SingleChildScrollView(
              child: DetailPageImage(
                entity: entity,
                index: 0,
                heroTag: tag,
                heroScope: 'feed',
                heroImageUrl: square,
                heroImageDecodeWidth: 540,
                // The page's data is there in the frame a Hero measures the
                // page in, where the flight takes the page's Hero child.
                detailUrl: large,
                downloadMode: false,
                selected: false,
                onToggleSelect: () {},
                onLongPress: () {},
              ),
            ),
          ).createRoute(navigatorKey.currentContext!),
        ),
      );
      Finder inFlight(Finder finder) =>
          find.descendant(of: find.byType(HeroRectClip), matching: finder);
      await tester.pump();
      for (final ms in [150, 150]) {
        await tester.pump(Duration(milliseconds: ms));
        final flying = tester.widgetList<PixivImage>(
          inFlight(find.byType(PixivImage)),
        );
        expect([for (final image in flying) image.url], [square]);
        expect(flying.single.fit, BoxFit.fitWidth);
        expect(flying.single.alignment, Alignment.topCenter);
      }

      await tester.pump(MotionTokens.pageTransition);
      expect(find.byType(HeroRectClip), findsNothing, reason: 'landed');
      double work() => tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (w) => w is PixivImage && w.url == large,
              ),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;
      expect(work(), 0, reason: 'unseen until decoded');
      await pumpIoUntil(tester, () => client.bodies.isNotEmpty);
      final body = client.bodies.single..add(onePixelPng);
      unawaited(body.close());
      await pumpIoUntil(tester, () => work() == 1);
      await tester.pump(MotionTokens.imageFade);

      // The return carries the whole work: its own copy of the page is built
      // anew in the flight, shown. The card's square comes back over its top.
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump();
      final squareShown = <double>[];
      while (find.byType(HeroRectClip).evaluate().isNotEmpty) {
        expect(
          tester.widget<AnimatedOpacity>(
            inFlight(find.byType(AnimatedOpacity)),
          ),
          isA<AnimatedOpacity>().having((w) => w.opacity, 'opacity', 1),
        );
        squareShown.add(
          tester
              .widget<Opacity>(
                find
                    .ancestor(
                      of: inFlight(find.byKey(const ValueKey('card'))),
                      matching: find.byType(Opacity),
                    )
                    .first,
              )
              .opacity,
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(squareShown.first, 0);
      expect(squareShown.last, greaterThan(0.9));
      expect(squareShown.where((o) => o > 0 && o < 1), isNotEmpty);
      for (var i = 1; i < squareShown.length; i++) {
        expect(squareShown[i], greaterThanOrEqualTo(squareShown[i - 1]));
      }
      await unmountPastReleaseGrace(tester);
    },
  );

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

  // The page over the card on the card's navigator, or on the root one
  // over the route holding it, as the viewer over a branch's detail page.
  for (final nested in [false, true]) {
    testWidgets('chrome over a flight steps aside until the landing; the clip '
        'follows the page over the card (nested: $nested)', (tester) async {
      setViewSize(tester, const Size(400, 800));
      late BuildContext root;
      late BuildContext feed;
      late PageRoute<void> pushed;
      var opened = 0;
      PageRoute<void> page(Widget child, {bool shared = false}) =>
          FuncPage<void>(
                transitionDuration: const Duration(milliseconds: 400),
                reverseTransitionDuration: const Duration(milliseconds: 400),
                sharedElement: shared,
                child: child,
              ).createRoute(root)
              as PageRoute<void>;
      Widget at(Offset offset, Widget child) =>
          Positioned(left: offset.dx, top: offset.dy, child: child);
      Widget art(double side) => Hero(
        tag: 'art',
        flightShuttleBuilder: illustHeroFlightShuttleBuilder,
        child: SizedBox.square(dimension: side),
      );
      // A card under a 100px app bar with its badge, a detail page whose
      // image runs under its control; chrome away from the image stays.
      void open() => Navigator.of(feed, rootNavigator: nested).push(
        pushed = page(
          Stack(
            children: [
              at(Offset.zero, art(400)),
              at(
                const Offset(10, 10),
                HeroChrome(child: Text('control ${++opened}')),
              ),
              at(const Offset(0, 700), const HeroChrome(child: Text('off'))),
            ],
          ),
          shared: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              root = context;
              return Navigator(
                observers: [HeroController()],
                onGenerateRoute: (_) => page(
                  Builder(
                    builder: (context) {
                      feed = context;
                      return Scaffold(
                        appBar: const PreferredSize(
                          preferredSize: Size.fromHeight(100),
                          child: SizedBox.shrink(),
                        ),
                        body: Stack(
                          children: [
                            at(const Offset(0, 200), art(100)),
                            at(
                              const Offset(0, 200),
                              const HeroChrome(child: Text('badge')),
                            ),
                            at(
                              const Offset(300, 600),
                              const HeroChrome(child: Text('far')),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      double chrome(String label) => tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;

      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        [chrome('badge'), chrome('control 1'), chrome('far'), chrome('off')],
        [0, 0, 1, 1],
      );
      // The card's app bar cuts the image only as far as the background of
      // the page over it has yet to cover it.
      final shown = MotionTokens.sharedElementBackdropIn.transform(
        pushed.animation!.value,
      );
      expect(shown, inExclusiveRange(0, 1));
      expect(_heroClipRect(tester).top, closeTo(100 * (1 - shown), 0.5));
      // Not a card's flight: no bars are lifted over it.
      expect(_liftedBars(tester), isEmpty);
      await tester.pumpAndSettle();
      expect(chrome('control 1'), 1);

      // Back, then the card again while the image flies home: the flight
      // goes on to the new page, whose control waits for it too.
      Navigator.of(feed, rootNavigator: nested).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect([chrome('badge'), chrome('control 1')], [0, 0]);
      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(chrome('control 2'), 0);
      await tester.pumpAndSettle();
      expect(chrome('control 2'), 1);
      expect(tester.getTopLeft(find.byType(Hero).last), Offset.zero);
    });
  }

  testWidgets('a card flight lifts the card page\'s bars over the image: '
      'they slide and fade away as it opens and back as it returns', (
    tester,
  ) async {
    setViewSize(tester, const Size(400, 800));
    late BuildContext root;
    late NavigatorState navigator;
    PageRoute<void> page(Widget child, {bool shared = false}) =>
        FuncPage<void>(
              transitionDuration: const Duration(milliseconds: 400),
              reverseTransitionDuration: const Duration(milliseconds: 400),
              sharedElement: shared,
              child: child,
            ).createRoute(root)
            as PageRoute<void>;
    Widget art(Widget child) => Hero(
      tag: 'card',
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: child,
    );
    // A card right under a 100px app bar, over a 100px bottom bar.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            root = context;
            return Navigator(
              observers: [HeroController()],
              onGenerateRoute: (_) => page(
                Builder(
                  builder: (context) {
                    navigator = Navigator.of(context);
                    return Scaffold(
                      appBar: const PreferredSize(
                        preferredSize: Size.fromHeight(100),
                        child: ColoredBox(color: Colors.green),
                      ),
                      body: ListView(
                        children: [
                          Align(
                            alignment: Alignment.topLeft,
                            child: art(
                              const IllustHeroCardFrame(
                                child: SizedBox.square(dimension: 200),
                              ),
                            ),
                          ),
                        ],
                      ),
                      bottomNavigationBar: _bottomBar,
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    const top = Rect.fromLTRB(0, 0, 400, 100);
    const bottom = Rect.fromLTRB(0, 700, 400, 800);
    // Each bar [shown] of the way in, its content as faded.
    void expectBars(double shown) {
      final bars = _liftedBars(tester);
      expect(bars.map((bar) => bar.opacity), everyElement(shown));
      expect(bars.map((bar) => bar.rect), [
        top.translate(0, -100 * (1 - shown)),
        bottom.translate(0, 100 * (1 - shown)),
      ]);
    }

    double shown() => _liftedBars(tester).first.opacity;
    List<Rect> covered() =>
        (tester.renderObject(find.byType(HeroBarsCover)) as dynamic)
                .debugLastPaintedRects
            as List<Rect>;

    unawaited(
      navigator.push(
        page(
          Align(
            alignment: Alignment.topCenter,
            child: art(const SizedBox.square(dimension: 400)),
          ),
          shared: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // Takeoff: the bars where they were, over the image, which the app
    // bar no longer cuts; the real ones covered.
    expectBars(1);
    expect(covered(), [top, bottom]);
    expect(_heroPaintClipRect(tester)!.top, 0);
    await tester.pump(const Duration(milliseconds: 150));
    final opening = shown();
    expect(opening, inExclusiveRange(0, 1));
    expectBars(opening);
    await tester.pumpAndSettle();
    expect(_liftedBars(tester), isEmpty);
    expect(covered(), isEmpty);

    navigator.pop();
    await tester.pump();
    await tester.pump();
    expectBars(0);
    expect(covered(), [top, bottom]);
    await tester.pump(const Duration(milliseconds: 150));
    final returning = shown();
    expect(returning, inExclusiveRange(0, 1));
    expectBars(returning);
    await tester.pump(const Duration(milliseconds: 240));
    expect(shown(), greaterThan(returning));
    await tester.pumpAndSettle();
    expect(_liftedBars(tester), isEmpty);
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

/// The card page's bars a flight last painted over its image, and their
/// content's opacity; none outside a card flight.
List<({Rect rect, double opacity})> _liftedBars(WidgetTester tester) {
  final paint = find.byWidgetPredicate(
    (widget) => '${widget.runtimeType}' == '_LiftedBarsPaint',
  );
  if (paint.evaluate().isEmpty) return const [];
  return (tester.renderObject(paint) as dynamic).debugLastPaintedBars
      as List<({Rect rect, double opacity})>;
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
