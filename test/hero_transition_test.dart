import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/illust_fixtures.dart';
import 'illust_detail_page_test.dart';
import 'package:parfait/app/motion/hero_rect_clip.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_type_switch.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

void main() {
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

  testWidgets('drag-to-dismiss pops after the distance threshold', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
    );
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          body: DragToDismiss(
            onDismissed: () {
              dismissed = true;
              Navigator.of(context).pop();
            },
            child: const SizedBox(
              key: Key('dismissible-surface'),
              width: 200,
              height: 200,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(DragToDismiss), const Offset(0, 180));
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
    expect(find.byKey(const Key('dismissible-surface')), findsNothing);
  });

  testWidgets('feed → detail → viewer keeps one hero tag family', (
    tester,
  ) async {
    // The spatial contract: one illustHeroTag(scope, id) base flows feed
    // card → detail page-0 → viewer page-0; only the page suffix differs.
    // Asserted through the real route glue (openIllust / openImageViewer /
    // heroTagForPage), so a second tag family or a lost scope fails here.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Detail pages embed VisibilityDetector trackers — zero interval uses
    // post-frame callbacks instead of a periodic timer.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;

    final (container, _, _) = await makeWorld();
    final entity = parseIllust(
      illustJson(42, pageCount: 2, withMetaPages: true),
    );
    container.read(illustStoreProvider).mergeAll([entity]);
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final baseTag = illustHeroTag('feed', 42);
      unawaited(
        router.push<void>(
          '/recommended/illust/42',
          extra: IllustRouteExtra(entity: entity, heroScope: 'feed'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

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
      _testPageRoute<void>(
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
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

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
      _testPageRoute<void>(
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

  testWidgets('Hero pop flight stays below the floating type switch', (
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
        theme: replicaTheme(Brightness.light),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppTypeSwitch<String>(
                options: const [
                  (value: 'illust', label: '插画'),
                  (value: 'novel', label: '小说'),
                ],
                selected: 'illust',
                onSelected: (_) {},
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 40),
                  Hero(
                    tag: 'float-switch-hero',
                    flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                    child: const ColoredBox(
                      color: Colors.red,
                      child: SizedBox(height: 300),
                    ),
                  ),
                  const SizedBox(height: 1200),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // Scroll the list up so the hero's landing slot slides under the
    // switch row, then reverse slightly: the row floats back in on top.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 30));
    await tester.pumpAndSettle();

    final rowRect = tester.getRect(find.byType(AppTypeSwitch<String>));
    final heroRect = tester.getRect(
      find.byWidgetPredicate((w) => w is Hero && w.tag == 'float-switch-hero'),
    );
    // The row is floating above the content and the hero's landing rect
    // overlaps it — without a clip the returning image would paint on top.
    expect(rowRect.top, greaterThanOrEqualTo(0));
    expect(rowRect.overlaps(heroRect), isTrue);

    navigatorKey.currentState!.push(
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: Hero(
              tag: 'float-switch-hero',
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

    // The landing boundary is the floating row's bottom edge: without the
    // positive overlap feeding the measured clip, the top edge would stay
    // at the detail page's zero for the whole flight. It must visibly
    // retract toward the row instead.
    expect(find.byType(HeroRectClip), findsOneWidget);
    expect(mid.top, greaterThan(start.top));
    expect(_heroPaintClipRect(tester), mid);

    // Converge with the flight: the last measured clip lands on the row's
    // bottom edge, so the image never paints across the floating row.
    var lastClip = _heroPaintClipRect(tester);
    while (find.byType(HeroRectClip).evaluate().isNotEmpty) {
      lastClip = _heroPaintClipRect(tester) ?? lastClip;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      lastClip!.top,
      closeTo(rowRect.bottom, 1.5),
      reason: 'the return clip must land at the switch row bottom edge',
    );
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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

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
      _testPageRoute<void>(
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
    expect(find.byType(HeroRectClip), findsOneWidget);
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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

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
      _testPageRoute<void>(
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
    expect(find.byType(HeroRectClip), findsOneWidget);
    expect(early.top, greaterThan(mid.top));
    expect(early.bottom, closeTo(mid.bottom, 0.001));
    expect(_heroPaintClipRect(tester), mid);
    await tester.pumpAndSettle();
  });

  testWidgets('Hero flight shuttle rounds from the card corner to the rect', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Hero(
            tag: 'radius-hero',
            flightShuttleBuilder: illustHeroFlightShuttleBuilder,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 160, height: 220),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    navigatorKey.currentState!.push(
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: Hero(
              tag: 'radius-hero',
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final pushSamples = await _sampleShuttleRadius(tester);

    // Push: the shuttle starts rounded like the card and straightens toward
    // the rectangular detail endpoint instead of snapping at landing.
    expect(pushSamples.length, greaterThan(2));
    expect(pushSamples.first, greaterThan(pushSamples.last));
    for (var i = 1; i < pushSamples.length; i++) {
      expect(pushSamples[i], lessThanOrEqualTo(pushSamples[i - 1]));
    }
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final popSamples = await _sampleShuttleRadius(tester);

    // Pop: the same curve runs in reverse — nearly square first, rounding
    // back toward the card's 12.
    expect(popSamples.length, greaterThan(2));
    expect(popSamples.last, greaterThan(popSamples.first));
    for (var i = 1; i < popSamples.length; i++) {
      expect(popSamples[i], greaterThanOrEqualTo(popSamples[i - 1]));
    }
    await tester.pumpAndSettle();
  });

  testWidgets('the card artwork frame clips without an outline', (
    tester,
  ) async {
    final theme = replicaTheme(Brightness.light);
    final (container, _, _) = await makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: theme,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: IllustCard(entity: parseIllust(illustJson(50))),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    });

    final hero = find.byWidgetPredicate(
      (w) => w is Hero && w.tag == illustHeroTag('feed', 50),
    );
    final frame = find.descendant(
      of: hero,
      matching: find.byType(IllustHeroCardFrame),
    );
    expect(frame, findsOneWidget);
    final clip = tester.widget<ClipRRect>(
      find.descendant(of: frame, matching: find.byType(ClipRRect)).first,
    );
    expect(clip.borderRadius, FuncShape.card);
    final outlines = find.descendant(
      of: frame,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    );
    expect(outlines, findsNothing);
  });

  testWidgets('a card flight paints no outline either way', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    const tag = 'border-hero';
    Widget plainHero(Widget child) => Hero(
      tag: tag,
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: child,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: plainHero(
            const IllustHeroCardFrame(
              child: ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 160, height: 220),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    navigatorKey.currentState!.push(
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: plainHero(
              const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 350, height: 500),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final pushSamples = await _sampleShuttleBorder(tester);
    expect(pushSamples.length, greaterThan(2));
    expect(pushSamples, everyElement(isNull));
    await tester.pumpAndSettle();

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final popSamples = await _sampleShuttleBorder(tester);
    expect(popSamples.length, greaterThan(2));
    expect(popSamples, everyElement(isNull));
    await tester.pumpAndSettle();
  });

  group('a cropped tall card', () {
    // The card shows the top of a 1:3 image in a 1:2 box.
    const aspect = 1 / 3;
    const tag = 'crop-hero';
    const shuttleKey = ValueKey('crop-shuttle');

    Future<GlobalKey<NavigatorState>> pumpCard(WidgetTester tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: 100,
                  height: 200,
                  child: Hero(
                    tag: tag,
                    flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                    child: const IllustHeroCardFrame(
                      cropAspect: aspect,
                      child: ColoredBox(color: Colors.red),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return navigatorKey;
    }

    /// The detail end: a [detailSize] box whose image is contained, like
    /// the detail page's `BoxFit.contain` artwork.
    PageRoute<void> detailRoute(Size detailSize) => _testPageRoute<void>(
      builder: (_) => Scaffold(
        body: Center(
          child: SizedBox.fromSize(
            size: detailSize,
            child: Hero(
              tag: tag,
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: const KeyedSubtree(
                key: shuttleKey,
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ),
    );

    /// The shuttle's clip box and the image rect inside it, once per frame.
    Future<List<(Rect, Rect)>> sampleFlight(WidgetTester tester) async {
      final clip = find.descendant(
        of: find.byType(HeroRectClip),
        matching: find.byType(ClipRRect),
      );
      final image = find.descendant(
        of: find.byType(HeroRectClip),
        matching: find.byKey(shuttleKey),
      );
      final samples = <(Rect, Rect)>[];
      for (var i = 0; i < 60; i++) {
        if (image.evaluate().isNotEmpty) {
          samples.add((tester.getRect(clip.first), tester.getRect(image)));
        } else if (samples.isNotEmpty) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      return samples;
    }

    Matcher near(double value) => closeTo(value, 4);

    /// Card look: full width, top-aligned, the rest of the image below.
    void expectCoverTop((Rect, Rect) sample) {
      final (box, image) = sample;
      expect(image.left, near(box.left));
      expect(image.top, near(box.top));
      expect(image.width, near(box.width));
      expect(image.height, near(box.width / aspect));
    }

    /// Detail look: the whole image contained and centred in the box.
    void expectContained((Rect, Rect) sample) {
      final (box, image) = sample;
      final height = math.min(box.height, box.width / aspect);
      expect(image.height, near(height));
      expect(image.width, near(height * aspect));
      expect(image.center.dx, near(box.center.dx));
      expect(image.center.dy, near(box.center.dy));
    }

    for (final (name, detailSize) in [
      ('phone', const Size(200, 600)),
      ('two-pane stage', const Size(600, 400)),
    ]) {
      testWidgets('flies from the top crop to the whole image ($name)', (
        tester,
      ) async {
        final navigatorKey = await pumpCard(tester);
        navigatorKey.currentState!.push(detailRoute(detailSize));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        final push = await sampleFlight(tester);
        expect(push.length, greaterThan(2));
        expectCoverTop(push.first);
        expectContained(push.last);
        await tester.pumpAndSettle();

        navigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        final pop = await sampleFlight(tester);
        expect(pop.length, greaterThan(2));
        expectContained(pop.first);
        expectCoverTop(pop.last);
        await tester.pumpAndSettle();
      });
    }
  });

  testWidgets('a detail-to-viewer-style flight grows no border', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    const tag = 'no-card-hero';
    Widget plainHero(Widget child) => Hero(
      tag: tag,
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: child,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: plainHero(
              const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 160, height: 220),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    navigatorKey.currentState!.push(
      _testPageRoute<void>(
        builder: (_) => Scaffold(
          body: Center(
            child: plainHero(
              const ColoredBox(
                color: Colors.red,
                child: SizedBox(width: 350, height: 500),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Neither endpoint is an IllustHeroCardFrame — the whole flight must
    // stay borderless rather than painting a stray hairline.
    final samples = await _sampleShuttleBorder(tester);
    expect(samples.length, greaterThan(2));
    expect(samples, everyElement(isNull));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Hero landing clip reaches the screen edge while the bar is hidden',
    (tester) async {
      final (navigatorKey, _) = await _pumpBarClipHome(
        tester,
        initialVisible: 0,
      );

      navigatorKey.currentState!.push(_barClipDetailRoute());
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      // Bar fully hidden: the landing clip must run to the screen bottom,
      // not stop at the resting 100px bar edge.
      final last = await _lastFlightClip(tester);
      expect(last.bottom, closeTo(800, 1));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Hero landing clip stops at the fully visible bottom bar', (
    tester,
  ) async {
    final (navigatorKey, _) = await _pumpBarClipHome(
      tester,
      initialVisible: 100,
    );

    navigatorKey.currentState!.push(_barClipDetailRoute());
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    final last = await _lastFlightClip(tester);
    expect(last.bottom, closeTo(700, 1));
    await tester.pumpAndSettle();
  });

  testWidgets('Hero landing clip follows the bottom bar sliding mid-flight', (
    tester,
  ) async {
    final (navigatorKey, visibleExtent) = await _pumpBarClipHome(
      tester,
      initialVisible: 0,
    );

    navigatorKey.currentState!.push(_barClipDetailRoute());
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // While the bar is hidden the clip reaches the screen edge...
    final early = _heroClipRect(tester);
    expect(early.bottom, closeTo(800, 1));

    // ...then the bar starts sliding back mid-flight and the landing
    // clip retracts to its live edge — a bar half-visible at landing
    // means height - 50, not the resting 100.
    visibleExtent.value = 50;
    final last = await _lastFlightClip(tester);
    expect(last.bottom, closeTo(750, 1));
    await tester.pumpAndSettle();
  });
}

const _barClipHeroTag = 'bar-clip-hero';

/// Pumps a home route whose only chrome is the published shell metrics —
/// [HomeShellChrome] with a caller-owned [ValueNotifier], so a test can
/// slide the bar's visible extent exactly like `FuncShellBottomNav` does.
Future<(GlobalKey<NavigatorState>, ValueNotifier<double>)> _pumpBarClipHome(
  WidgetTester tester, {
  required double initialVisible,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final visibleExtent = ValueNotifier<double>(initialVisible);
  addTearDown(visibleExtent.dispose);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      navigatorKey: navigatorKey,
      home: HomeShellChrome(
        bottomBarExtent: 100,
        bottomBarVisibleExtent: visibleExtent,
        child: Scaffold(
          body: ListView(
            children: const [
              SizedBox(height: 600),
              Hero(
                tag: _barClipHeroTag,
                flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                child: ColoredBox(
                  color: Colors.red,
                  child: SizedBox(height: 300),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (navigatorKey, visibleExtent);
}

PageRoute<void> _barClipDetailRoute() => _testPageRoute<void>(
  builder: (_) => Scaffold(
    body: Center(
      child: Hero(
        tag: _barClipHeroTag,
        flightShuttleBuilder: illustHeroFlightShuttleBuilder,
        child: const ColoredBox(
          color: Colors.red,
          child: SizedBox(width: 350, height: 500),
        ),
      ),
    ),
  ),
);

/// Pumps until the flight shuttle unmounts and returns the last clip rect
/// it painted with — the frame that must land on the bar's real edge.
Future<Rect> _lastFlightClip(WidgetTester tester) async {
  var last = _heroClipRect(tester);
  while (find.byType(HeroRectClip).evaluate().isNotEmpty) {
    last = _heroClipRect(tester);
    await tester.pump(const Duration(milliseconds: 16));
  }
  return last;
}

void _noop() {}

/// Samples the shuttle's corner radius once per frame for the whole flight.
/// The first frames can run before the placeholder reports a size (no radius
/// clip mounted) and the shuttle unmounts at landing, so samples are taken
/// only while the clip exists.
Future<List<double>> _sampleShuttleRadius(WidgetTester tester) async {
  final finder = find.descendant(
    of: find.byType(HeroRectClip),
    matching: find.byType(ClipRRect),
  );
  final samples = <double>[];
  for (var i = 0; i < 60; i++) {
    if (finder.evaluate().isNotEmpty) {
      samples.add(_shuttleRadius(tester));
    } else if (samples.isNotEmpty) {
      break;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  return samples;
}

double _shuttleRadius(WidgetTester tester) {
  final clip = tester.widget<ClipRRect>(
    find.descendant(
      of: find.byType(HeroRectClip),
      matching: find.byType(ClipRRect),
    ),
  );
  return (clip.borderRadius as BorderRadius).topLeft.x;
}

/// Samples the shuttle's border color once per frame for the whole flight,
/// or null on frames that paint no hairline. Same sampling gate as
/// [_sampleShuttleRadius]: the clip mounts one frame after the shuttle and
/// unmounts at landing.
Future<List<Color?>> _sampleShuttleBorder(WidgetTester tester) async {
  final finder = find.byType(HeroRectClip);
  final samples = <Color?>[];
  for (var i = 0; i < 60; i++) {
    if (finder.evaluate().isNotEmpty) {
      samples.add(_shuttleBorderColor(tester));
    } else if (samples.isNotEmpty) {
      break;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  return samples;
}

Color? _shuttleBorderColor(WidgetTester tester) {
  for (final element
      in find
          .descendant(
            of: find.byType(HeroRectClip),
            matching: find.byType(DecoratedBox),
          )
          .evaluate()) {
    final box = element.widget as DecoratedBox;
    final decoration = box.decoration;
    if (box.position == DecorationPosition.foreground &&
        decoration is BoxDecoration &&
        decoration.border != null) {
      return decoration.border!.top.color;
    }
  }
  return null;
}

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
