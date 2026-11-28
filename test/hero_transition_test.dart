import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
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
import 'helpers/test_preferences.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';

void main() {
  ignoreOctoImageFades();
  // Every test that builds an image creates the network factory, which
  // listens to connectivity. Unanswered, a cancel's reply lands in a later
  // test's real async as an exception.
  setUp(answerConnectivityChannels);

  Future<({BuildContext root, NavigatorState nav, Route<void> firstRoute})>
  pumpHeroNavigator(WidgetTester tester, {required Widget firstChild}) async {
    setViewSize(tester, const Size(400, 800));
    late BuildContext root;
    late Route<void> firstRoute;
    final heroes = HeroController();
    addTearDown(heroes.dispose);
    await tester.pumpWidget(
      MaterialApp(
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
