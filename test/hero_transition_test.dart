import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/motion/hero_rect_clip.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/navigation/func_page.dart';
import 'package:parfait/app/navigation/route_extras.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/debug/hero_anomaly_log.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/leak_tracking.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/test_preferences.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';

void main() {
  ignoreOctoImageFades();
  // Every test that builds an image creates the network factory, which
  // listens to connectivity. Unanswered, a cancel's reply lands in a later
  // test's real async as an exception.
  setUp(answerConnectivityChannels);

  // The real router on the feed, then the detail page of the work in [json]
  // pushed with the feed's hero scope.
  Future<void> pushFromFeed(
    WidgetTester tester,
    Map<String, dynamic> json, {
    Map<int, Map<String, dynamic>> detailOverrides = const {},
  }) async {
    setViewSize(tester, const Size(390, 844));
    // Detail pages embed VisibilityDetector trackers — zero interval uses
    // post-frame callbacks instead of a periodic timer.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final (container, _, _) = await makeWorld(detailOverrides: detailOverrides);
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

  Future<({BuildContext root, NavigatorState nav, Route<void> firstRoute})>
  pumpHeroNavigator(
    WidgetTester tester, {
    required Widget firstChild,
    TargetPlatform? platform,
  }) async {
    setViewSize(tester, const Size(400, 800));
    late BuildContext root;
    late Route<void> firstRoute;
    final heroes = HeroController();
    addTearDown(heroes.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        home: Builder(
          builder: (context) {
            root = context;
            return Navigator(
              observers: [heroes],
              onGenerateRoute: (_) => firstRoute = FuncPage<void>(
                child: firstChild,
              ).createRoute(root),
            );
          },
        ),
      ),
    );
    final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
    return (root: root, nav: nav, firstRoute: firstRoute);
  }

  // A root page (the viewer) pairs its Hero with the top page of every
  // branch: the same work open in a branch out of sight shared the tag,
  // and the image flew to where that branch had it.
  testWidgets('the viewer pairs only with the branch on screen', (
    tester,
  ) async {
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

  // The flight self-check: a card end the user cannot see is logged and
  // announced; a flight between two live ends on screen is not.
  testWidgets('a flight from a card out of sight is logged, others not', (
    tester,
  ) async {
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

  // Within the tap window a push from a card is held to the tapped card's
  // box; a push from the detail page to the viewer, under the same tag,
  // starts from the detail image and is not.
  testWidgets('a push is held to the tapped card only when it leaves a card', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final tapped = GlobalKey();
    const tag = 'IllustHero:feed:8';
    Widget hero(Widget child) => Hero(
      tag: tag,
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: child,
    );
    Future<void> push(Widget page) async {
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => page),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await tester.pumpWidget(
      localizedApp(
        overrides: const [],
        navigatorKey: navigator,
        builder: promptHostBuilder,
        home: Stack(
          children: [
            hero(
              const IllustHeroCardFrame(child: SizedBox.square(dimension: 100)),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: SizedBox.square(key: tapped, dimension: 50),
            ),
          ],
        ),
      ),
    );
    final log = HeroAnomalyLog(SharedPreferencesAsync());
    noteHeroCardOpened(tester.element(find.byKey(tapped)), tag);

    await push(Center(child: hero(const SizedBox.square(dimension: 300))));
    expect(find.byType(HeroRectClip), findsOneWidget, reason: 'flying');
    final entries = (await tester.runAsync(log.read))!;
    expect(entries.single, contains('card end away from the tapped card'));
    await tester.pumpAndSettle();

    await push(hero(const SizedBox.expand()));
    expect(find.byType(HeroRectClip), findsOneWidget, reason: 'flying');
    expect(await tester.runAsync(log.read), hasLength(1));
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('only the entry page flies back; a drag from another page '
      'slides away, back leaves like any page', (tester) async {
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

  testWidgets(
    'detail page fetches large image once after Hero flight settles',
    (tester) async {
      setViewSize(tester, const Size(390, 844));
      final entity = parseIllust(illustJson(7, width: 400, height: 2000));
      final large = entity.imageUrls.large;
      final copy = entity.previewUrl(PreviewQuality.large);
      final client = HeldBodyClient(
        respond: (request) =>
            {_topSquareUrl, copy, large}.contains('${request.url}')
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
          previewQualityProvider.overrideWithValue(PreviewQuality.large),
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
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      );
      var warmed = false;
      unawaited(
        PixivImage.preload(
          navigatorKey.currentContext!,
          large,
          memCacheWidth: PixivImage.screenDecodeWidthOf(
            navigatorKey.currentContext!,
            listen: false,
          ),
          priority: ImageFetchPriority.foreground,
        ).then((_) => warmed = true),
      );
      await pumpIoUntil(tester, () => warmed);
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
                heroImageUrl: _topSquareUrl,
                heroImageDecodeWidth: 540,
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
      await tester.pumpAndSettle();
      expect(client.urls.where((url) => url == large), hasLength(1));
      await unmountPastReleaseGrace(tester);
    },
  );

  testWidgets('HeroChrome restores visibility after flight settles', (
    tester,
  ) async {
    final host = await pumpHeroNavigator(
      tester,
      firstChild: Stack(
        children: [
          Positioned(
            left: 0,
            top: 200,
            child: _hero('chrome-hero', width: 100, height: 100),
          ),
          const Positioned(
            left: 0,
            top: 200,
            child: HeroChrome(child: Text('badge')),
          ),
        ],
      ),
    );
    double opacityOf(String label) => tester
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

    unawaited(
      host.nav.push(
        FuncPage<void>(
          sharedElement: true,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: _hero('chrome-hero', width: 400, height: 400),
              ),
              const Positioned(
                left: 10,
                top: 10,
                child: HeroChrome(child: Text('control')),
              ),
            ],
          ),
        ).createRoute(host.root),
      ),
    );
    await tester.pumpAndSettle();
    expect(opacityOf('control'), 1);

    host.nav.pop();
    await tester.pumpAndSettle();
    expect(opacityOf('badge'), 1);
  });

  testWidgets(
    'iOS canvas drag dismiss launches Hero return flight on release',
    (tester) async {
      final host = await pumpHeroNavigator(
        tester,
        platform: TargetPlatform.iOS,
        firstChild: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Hero(
              tag: 'drag-hero',
              transitionOnUserGestures: true,
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: const SizedBox.square(
                dimension: 120,
                child: ColoredBox(color: Colors.red),
              ),
            ),
          ),
        ),
      );
      unawaited(
        host.nav.push(
          FuncPage<void>(
            sharedElement: true,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: Hero(
                  tag: 'drag-hero',
                  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                  child: const SizedBox.square(
                    dimension: 320,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ),
          ).createRoute(host.root),
        ),
      );
      await tester.pumpAndSettle();

      final drag = await tester.startGesture(const Offset(20, 300));
      await drag.moveBy(const Offset(30, 0));
      await drag.moveBy(const Offset(160, 0));
      await tester.pump();
      expect(host.nav.userGestureInProgress, isTrue);

      await drag.up();
      await tester.pump();
      expect(host.nav.userGestureInProgress, isFalse);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(HeroRectClip), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(HeroRectClip), findsNothing);
    },
  );

  testWidgets('Hero flight ignores deactivated endpoints without throwing', (
    tester,
  ) async {
    final host = await pumpHeroNavigator(
      tester,
      firstChild: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: _hero('deactivated-hero', width: 120, height: 120),
        ),
      ),
    );
    unawaited(
      host.nav.push(
        FuncPage<void>(
          sharedElement: true,
          child: Scaffold(
            body: Align(
              alignment: Alignment.center,
              child: _hero('deactivated-hero', width: 320, height: 320),
            ),
          ),
        ).createRoute(host.root),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(HeroRectClip), findsOneWidget);

    // Deactivate the source route mid-flight so _LiftedEndpoints sees !mounted.
    host.nav.removeRoute(host.firstRoute);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(HeroRectClip), findsNothing);
  });

  test('a failed anomaly write is logged and the next one lands', () async {
    installPreferencesForTest(_ListWriteFailsOnce());
    final log = HeroAnomalyLog(SharedPreferencesAsync());

    await log.add('lost');
    await log.add('kept');

    expect(await log.read(), ['kept']);
  });
}

/// In-memory preferences whose first `setStringList` fails, as on a full
/// disk that a later write finds freed.
final class _ListWriteFailsOnce extends InMemorySharedPreferencesAsync {
  _ListWriteFailsOnce() : super.empty();

  var _failed = false;

  @override
  Future<bool> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) {
    if (_failed) return super.setStringList(key, value, options);
    _failed = true;
    return Future.error(StateError('disk full'));
  }
}

/// A red Hero flying with the production shuttle builder.
Hero _hero(Object tag, {double? width, double? height}) => Hero(
  tag: tag,
  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
  child: ColoredBox(
    color: Colors.red,
    child: SizedBox(width: width, height: height),
  ),
);

const _topSquareUrl =
    'https://i.pximg.net/c/540x540_70/img-master/img/7_p0_square1200.jpg';
