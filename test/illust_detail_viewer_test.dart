import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/navigation/viewer_session.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/features/illust/detail/ugoira_viewer.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/image_network.dart';
import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'helpers/prompt_host.dart';

import 'helpers/illust_detail_page_support.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';

// §7 screen-reader representative paths — the three priority surfaces
// (author header, artwork viewer, comment composer). These are widget-tree
// semantic assertions only: TalkBack/Narrator device runs stay marked
// "unverified" in the acceptance ledger — a clean semantic tree here does
// not imply the AT path was exercised.

Widget _host(Widget child) {
  return withStalledImages(localizedApp(body: child));
}

double _scale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

void main() {
  // The detail page tracks the visible image page through
  // VisibilityDetector (compact-header page counter); a zero interval
  // defers updates to post-frame callbacks so no Timer outlives a test.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  group('ImageViewerPage (R3)', () {
    // The chrome toggle is session-level state (revision ①): reset it
    // between tests so one test's hidden chrome cannot leak into the next.
    setUp(debugResetViewerSession);

    const twoPages = [
      'https://i.pximg.net/1/original.jpg',
      'https://i.pximg.net/2/original.jpg',
    ];

    /// Pumps a viewer over [urls] and lets its first frame settle in.
    Future<void> pumpViewer(
      WidgetTester tester, {
      List<String> urls = twoPages,
      int initialPage = 0,
      bool loading = false,
    }) async {
      await tester.pumpWidget(
        withStalledImages(
          localizedApp(
            builder: promptHostBuilder,
            home: ImageViewerPage(
              urls: urls,
              initialPage: initialPage,
              loading: loading,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // System-back tests need the viewer pushed as a *second* route —
    // `handlePopRoute` -> maybePop refuses to pop the last route (the OS
    // would take over), so a stub home sits underneath.
    Future<void> pumpPushedViewer(
      WidgetTester tester, {
      List<String> urls = const ['https://i.pximg.net/1/original.jpg'],
    }) async {
      await tester.pumpWidget(
        withStalledImages(
          localizedApp(
            builder: promptHostBuilder,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ImageViewerPage(urls: urls),
                    ),
                  ),
                  child: const Text('open-viewer'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open-viewer'));
      await tester.pumpAndSettle();
    }

    testWidgets('zoomed viewer keeps vertical gestures for image pan', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        withStalledImages(
          localizedApp(
            builder: promptHostBuilder,
            navigatorKey: navigatorKey,
            home: const SizedBox.shrink(),
          ),
        ),
      );
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              ImageViewerPage(urls: ['https://i.pximg.net/1/original.jpg']),
        ),
      );
      await tester.pumpAndSettle();

      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value = Matrix4.identity()
        ..scaleByDouble(2, 2, 2, 1);
      await tester.pump();

      expect(
        tester.widget<DragToDismiss>(find.byType(DragToDismiss)).enabled,
        isFalse,
      );
      await tester.drag(find.byType(InteractiveViewer), const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsOneWidget);
    });

    testWidgets('a lone tap hides and restores the chrome', (tester) async {
      await pumpViewer(tester, initialPage: 1);
      expectViewerChrome(tester, visible: true);

      // Tap the media area — chrome fades out (mounted but opacity 0).
      // The tap resolves only after the double-tap window: pump past
      // ~kDoubleTapTimeout before asserting.
      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expectViewerChrome(tester, visible: false);

      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expectViewerChrome(tester, visible: true);
    });

    testWidgets(
      'scrubbing jumps to the target page without building crossed pages',
      (tester) async {
        await pumpViewer(
          tester,
          urls: [
            for (var i = 0; i < 5; i++) 'https://i.pximg.net/$i/original.jpg',
          ],
        );
        expect(find.byKey(const ValueKey('viewer-page-2')), findsNothing);

        final scrubber = find.byKey(const Key('viewer-page-scrubber'));
        expect(scrubber, findsOneWidget);
        // A thumb on the bar wanders: starting downward must still scrub,
        // not hand the drag to pull-to-dismiss.
        final gesture = await tester.startGesture(tester.getCenter(scrubber));
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        await gesture.moveBy(const Offset(320, 0));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.text('5 / 5'), findsOneWidget);
        expect(find.byKey(const ValueKey('viewer-page-2')), findsNothing);
      },
    );

    testWidgets('pages that arrive late open on the page asked for; the '
        'wait keeps the way out', (tester) async {
      // A restored viewer has no work in memory: the pages come with the
      // detail, and a snapshot may hold only the first.
      for (final urls in [const <String>[], twoPages.sublist(0, 1)]) {
        await pumpViewer(tester, urls: urls, initialPage: 1, loading: true);
        expect(find.byType(FeedLoading), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);
        expect(find.byKey(const Key('viewer-page-counter')), findsNothing);
      }
      await pumpViewer(tester, initialPage: 1);
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('viewer-page-1')).hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets(
      'hidden chrome belongs to the session: it survives page turns and '
      'route swaps (revision ①)',
      (tester) async {
        await pumpViewer(tester);

        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);

        // Page turn — the chrome stays hidden.
        await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        expectViewerChrome(tester, visible: false);

        // A route swap (replaceImageViewerPage builds a fresh widget on a
        // new route) keeps the session flag too.
        await pumpViewer(tester, initialPage: 1);
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);
      },
    );

    testWidgets(
      'double-tap runs the fit<->2.5 zoom cycle without toggling chrome',
      (tester) async {
        await pumpViewer(tester, urls: ['https://i.pximg.net/1/original.jpg']);

        expect(_scale(tester), 1.0);

        // fit → 2.5. The second tap must land inside the double-tap
        // window (>= kDoubleTapMinTime, < kDoubleTapTimeout).
        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(2.5, 0.01));
        expectViewerChrome(tester, visible: true);

        // 2.5 → fit
        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(1.0, 0.01));
      },
    );

    testWidgets(
      'tap/double-tap disambiguation: tap waits out the window, double-tap '
      'zooms, the next tap toggles chrome again',
      (tester) async {
        await pumpViewer(tester, urls: ['https://i.pximg.net/1/original.jpg']);

        // A lone tap resolves only after the double-tap window; pump past
        // ~kDoubleTapTimeout before asserting the chrome toggle.
        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);
        expect(_scale(tester), 1.0);

        // Double-tap zooms without touching the chrome.
        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(2.5, 0.01));
        expectViewerChrome(tester, visible: false);

        // The following lone tap toggles chrome again — the disambiguation
        // resolved cleanly instead of swallowing the tap.
        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: true);
      },
    );

    testWidgets('the save action submits the active page', (tester) async {
      final (container, transport, sinks) = await makeWorld();
      final entity = parseIllust(
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: ImageViewerPage(
            urls: [
              'https://i.pximg.net/1/original.jpg',
              'https://i.pximg.net/2/original.jpg',
            ],
            entity: entity,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.download));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final manager = container.read(downloadManagerProvider);
      expect(manager.tasks, hasLength(1));
      expect(manager.tasks.single.pageIndex, 0);
    });

    testWidgets('the save icon tracks the live download state (manager events '
        'subscription)', (tester) async {
      final (container, _, _) = await makeWorld();
      final entity = parseIllust(
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: ImageViewerPage(
            urls: [
              'https://i.pximg.net/1/original.jpg',
              'https://i.pximg.net/2/original.jpg',
            ],
            entity: entity,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.download));
      await tester.pump();

      // The task completes over the scripted transport; the manager's
      // event stream must rebuild the button into the exist-check —
      // without the subscription the icon stays a download glyph.
      final manager = container.read(downloadManagerProvider);
      await pumpUntil(
        tester,
        () => manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
        frames: 30,
      );
      expect(manager.tasks.single.status, DownloadStatus.succeeded);
      await tester.pump();
      expect(find.byIcon(UiIcons.checkCircle), findsOneWidget);
      // The exist state also disables the button (detail-page badge
      // semantics carried over).
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(UiIcons.checkCircle),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'explicit exits pop imperatively even while zoomed (Esc + back button)',
      (tester) async {
        await pumpPushedViewer(tester);
        expect(find.byType(ImageViewerPage), findsOneWidget);

        // Zoom in, then Esc — the route pops directly (imperative pop
        // does not reset zoom first; that is the system-back contract).
        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsNothing);
        expect(find.text('open-viewer'), findsOneWidget);
      },
    );

    testWidgets(
      'keyboard: arrows page, +/- zooms, 0 resets, F toggles chrome',
      (tester) async {
        await pumpViewer(tester);

        // Arrows page forward/back.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsOneWidget);

        // +/- zoom in place, 0 resets.
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pumpAndSettle();
        expect(_scale(tester), greaterThan(1.0));
        // Held down, it stops where a pinch does.
        for (var i = 0; i < 12; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.equal);
          await tester.pumpAndSettle();
        }
        expect(_scale(tester), closeTo(ImageViewerPage.maxScale, 0.01));
        await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(1.0, 0.01));

        // F toggles the chrome.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: true);
      },
    );

    testWidgets(
      'mouse wheel zooms the active page; shift+wheel turns the page',
      (tester) async {
        await pumpViewer(tester);
        final center = tester.getCenter(find.byType(PageView));

        // Wheel-up zooms in around the pointer; wheel-down zooms back.
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.pumpAndSettle();
        expect(_scale(tester), greaterThan(1.0));
        // The pager must not consume the wheel event — still page 1.
        expect(find.text('1 / 2'), findsOneWidget);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(1.0, 0.01));

        // Shift+wheel pages instead of zooming.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      },
    );

    testWidgets('a page decodes a preview until zoomed, then the whole file', (
      tester,
    ) async {
      await pumpViewer(tester, urls: [twoPages.first]);
      PixivImage page() => tester.widget<PixivImage>(find.byType(PixivImage));
      final preview = ImageViewerPage.previewDecodeWidth(
        tester.element(find.byType(PageView)),
      );
      expect(page().memCacheWidth, preview);
      // Without a Hero the preview still stands in while the file decodes.
      expect(page().transitionKey, isNotNull);

      final zoom = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      for (final (scale, width) in [
        (1.4, preview),
        (ImageViewerPage.fullDecodeScale, null),
        // Back at fit, the page keeps the whole file: no swap back.
        (1.0, null),
      ]) {
        zoom.value = Matrix4.diagonal3Values(scale, scale, 1);
        await tester.pump();
        expect(page().memCacheWidth, width, reason: 'at $scale');
      }
    });

    testWidgets('system back while zoomed resets to fit and keeps the route', (
      tester,
    ) async {
      await pumpPushedViewer(tester);

      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byType(PageView));
      await tester.pumpAndSettle();
      expect(_scale(tester), greaterThan(1.0));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      // Zoom reset; the route stayed.
      expect(_scale(tester), closeTo(1.0, 0.01));
      expect(find.byType(ImageViewerPage), findsOneWidget);

      // Now at fit — the next system back leaves the route.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsNothing);
    });

    testWidgets(
      'the zoom gate still intercepts after a route swap rebuilds the '
      'viewer state',
      (tester) async {
        await pumpPushedViewer(tester);

        // Route swap: replaceImageViewerPage pushes a fresh viewer route
        // (new State) over the same underlying home.
        final context = tester.element(find.byType(ImageViewerPage));
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => ImageViewerPage(
              urls: const ['https://i.pximg.net/1/original.jpg'],
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();
        expect(_scale(tester), greaterThan(1.0));

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(1.0, 0.01));
        expect(find.byType(ImageViewerPage), findsOneWidget);
      },
    );

    testWidgets(
      'pointer controls: mouse drag stays mounted, hover arrows page, hotzone reveals chrome, right-click menu and adaptive overlays work',
      (tester) async {
        const wide = Size(1024, 768);
        setViewSize(tester, wide);
        final (container, _, _) = await makeWorld();
        final entity = parseIllust(
          illustJson(42, pageCount: 2, withMetaPages: true),
        );
        await tester.pumpWidget(
          withStalledImages(
            InputModalityScope(
              initialModality: InputModality.pointer,
              child: localizedApp(
                container: container,
                builder: promptHostBuilder,
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ImageViewerPage(urls: twoPages, entity: entity),
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(const Offset(512, 384));
        await mouse.down(const Offset(512, 384));
        await mouse.moveBy(const Offset(0, 260));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsOneWidget);

        await tester.pump();
        expect(find.byKey(const Key('viewer-next-page')), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('viewer-next-page')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.byKey(const Key('viewer-prev-page')), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('viewer-prev-page')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);
        await mouse.moveTo(const Offset(512, 12));
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: true);
        await mouse.moveTo(const Offset(512, 384));
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();

        await tester.tap(
          find.byType(PageView),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<void>), findsWidgets);
        await tester.tapAt(
          const Offset(20, 400),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byTooltip('跳转到页码'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppBottomSheet), findsNothing);
        await tester.tap(find.text('2').last, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);

        await tester.tap(
          find.byIcon(AppIcons.info),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text(entity.title), findsOneWidget);
        await tester.tapAt(
          const Offset(20, 384),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
      },
    );
  });

  group('UgoiraViewer desktop controls', () {
    testWidgets(
      'Space toggles playback unless editing text; speed selector and right-click menu work',
      (tester) async {
        setViewSize(tester, const Size(1024, 768));
        final (container, _, _) = await makeWorld();
        await tester.pumpWidget(
          withStalledImages(
            InputModalityScope(
              initialModality: InputModality.pointer,
              child: localizedApp(
                container: container,
                builder: promptHostBuilder,
                home: const Scaffold(
                  body: Column(
                    children: [
                      SizedBox(height: 44, child: TextField()),
                      SizedBox(
                        height: 300,
                        child: UgoiraViewer(
                          illustId: 42,
                          previewUrl: 'https://i.pximg.net/1/large.jpg',
                          width: 400,
                          height: 300,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(find.byIcon(AppIcons.playCircle), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(find.byIcon(AppIcons.playCircle), findsOneWidget);

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.byType(UgoiraViewer)));
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(find.byIcon(AppIcons.playCircle), findsNothing);

        await tester.tap(find.text('1x'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('2x'));
        await tester.pumpAndSettle();
        expect(find.text('2x'), findsOneWidget);

        await tester.tap(
          find.byType(UgoiraViewer),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<void>), findsWidgets);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('viewer semantics', () {
    testWidgets('viewer pages announce a per-page image and chrome controls', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const ImageViewerPage(urls: ['u1', 'u2'])));
      await tester.pump();

      // The media surface announces the page position as an image node —
      // without it a screen reader hits a silent canvas (PRD R4).
      expect(find.bySemanticsLabel('第 1 页，共 2 页'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('第 1 页，共 2 页')),
        isSemantics(isImage: true),
      );

      // Chrome controls are named buttons: the page counter (jump sheet)
      // and fit.
      expect(
        tester.getSemantics(find.byTooltip('跳转到页码')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.byTooltip('适应屏幕')),
        isSemantics(isButton: true, hasTapAction: true),
      );
    });

    testWidgets(
      'ImageViewer supports wheel zoom with 1.0x snap, multi-page hover scrubber, and wide info panel pop-before-navigate',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          setViewSize(tester, const Size(1280, 800));
          final container = await signedInApiContainer(
            PixivApi().client,
            overrides: [
              imageWorkerProvider.overrideWithValue(stalledImageWorker()),
            ],
          );
          final single = parseIllust(illustJson(10, pageCount: 1));
          final multi = parseIllust(
            illustJson(42, pageCount: 2, withMetaPages: true),
          );

          Future<GoRouter> pumpViewer(IllustEntity entity) async {
            final router = GoRouter(
              initialLocation: '/recommended/viewer',
              routes: [
                GoRoute(
                  path: '/recommended',
                  builder: (_, _) => const Text('recommended-base'),
                  routes: [
                    GoRoute(
                      path: 'viewer',
                      builder: (_, _) => ImageViewerPage(
                        urls: [
                          for (var i = 0; i < entity.pageCount; i++)
                            entity.originalUrlAt(i)!,
                        ],
                        entity: entity,
                      ),
                    ),
                    GoRoute(
                      path: 'user/:id',
                      builder: (_, state) =>
                          Text('user-${state.pathParameters['id']}'),
                    ),
                    GoRoute(
                      path: 'search/results',
                      builder: (_, state) =>
                          Text('search-${state.uri.queryParameters['q']}'),
                    ),
                  ],
                ),
              ],
            );
            addTearDown(router.dispose);
            await tester.pumpWidget(
              localizedRouterApp(
                router,
                container: container,
                builder: (_, child) => InputModalityScope(child: child!),
              ),
            );
            await tester.pump();
            return router;
          }

          // Single-page omits scrubber; 2-page pointer viewer shows scrubber.
          await pumpViewer(single);
          expect(find.byKey(const Key('viewer-page-scrubber')), findsNothing);

          await pumpViewer(multi);
          expect(find.byKey(const Key('viewer-page-scrubber')), findsOneWidget);

          // Pointer wheel zoom in (>1.0) then zoom out snaps cleanly to 1.0.
          double stageScale() => tester
              .widget<InteractiveViewer>(
                find.byKey(const ValueKey('viewer-page-0')),
              )
              .transformationController!
              .value
              .getMaxScaleOnAxis();

          final pointer = TestPointer(9, PointerDeviceKind.mouse);
          final stageCenter = tester.getCenter(
            find.byKey(const ValueKey('viewer-page-0')),
          );
          await tester.sendEventToBinding(pointer.hover(stageCenter));
          await tester.pump();
          await tester.sendEventToBinding(
            pointer.scroll(const Offset(0, -120)),
          );
          await tester.pumpAndSettle();
          expect(stageScale(), greaterThan(1.15));

          await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
          await tester.pumpAndSettle();
          expect(stageScale(), closeTo(1.0, 0.001));

          // Horizontal scroll never shrinks; down-scroll at 1.0 stays identity;
          // Shift+horizontal wheel turns pages; zooming out from 2.5 snaps to 1.0.
          await tester.sendEventToBinding(pointer.scroll(const Offset(120, 0)));
          await tester.pumpAndSettle();
          expect(stageScale(), closeTo(1.0, 0.001));
          await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
          await tester.pumpAndSettle();
          final fitMatrix = tester
              .widget<InteractiveViewer>(
                find.byKey(const ValueKey('viewer-page-0')),
              )
              .transformationController!
              .value;
          expect(fitMatrix, equals(Matrix4.identity()));

          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          try {
            await tester.sendEventToBinding(
              pointer.scroll(const Offset(120, 0)),
            );
            await tester.pumpAndSettle();
            expect(find.text('2 / 2'), findsOneWidget);
            await tester.sendEventToBinding(
              pointer.scroll(const Offset(-120, 0)),
            );
            await tester.pumpAndSettle();
            expect(find.text('1 / 2'), findsOneWidget);
          } finally {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          }

          // Wheel zoom out from 2.5x snaps cleanly to 1.0 identity without corner-lock,
          // and a pointer drag mid-animation stops the zoom animation immediately.
          final controller0 = tester
              .widget<InteractiveViewer>(
                find.byKey(const ValueKey('viewer-page-0')),
              )
              .transformationController!;
          controller0.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
          await tester.pump();
          for (var i = 0; i < 5; i++) {
            await tester.sendEventToBinding(
              pointer.scroll(const Offset(0, 120)),
            );
          }
          await tester.pumpAndSettle();
          expect(controller0.value, equals(Matrix4.identity()));

          await tester.sendEventToBinding(
            pointer.scroll(const Offset(0, -120)),
          );
          await tester.pump(const Duration(milliseconds: 40));
          final viewer0 = tester.widget<InteractiveViewer>(
            find.byKey(const ValueKey('viewer-page-0')),
          );
          viewer0.onInteractionStart!(ScaleStartDetails());
          final frozen = controller0.value.clone();
          await tester.pump(const Duration(milliseconds: 300));
          expect(controller0.value, equals(frozen));
          await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
          await tester.pumpAndSettle();

          // Hiding chrome via F excludes hidden controls from keyboard focus
          // and hides desktop page arrows even while pointer hovers the stage.
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.pumpAndSettle();
          final nextArrow = find.byKey(const Key('viewer-next-page'));
          expect(
            tester
                .widget<AnimatedOpacity>(
                  find
                      .descendant(
                        of: nextArrow,
                        matching: find.byType(AnimatedOpacity),
                      )
                      .first,
                )
                .opacity,
            0.0,
          );
          for (var i = 0; i < 8; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.pumpAndSettle();

          // Right-click menu uses localized 2.5× zoom label (not '100%'), and
          // dragging the scrubber keeps the bubble when returning to page 0.
          await tester.tapAt(
            tester.getCenter(find.byType(ImageViewerPage)),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          expect(find.text('放大（2.5×）'), findsOneWidget);
          expect(find.text('100%'), findsNothing);
          await tester.tapAt(
            const Offset(10, 10),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pumpAndSettle();
          final slider = tester.widget<Slider>(find.byType(Slider));
          slider.onChanged!(1);
          await tester.pump();
          slider.onChanged!(0);
          await tester.pump();
          expect(find.text('1 / 2'), findsWidgets);
          slider.onChangeEnd!(0);
          await tester.pumpAndSettle();

          // Open docked 320dp info panel and pop-before-navigate via author link.
          await tester.tap(find.byIcon(AppIcons.info));
          await tester.pumpAndSettle();
          final panel = find.byKey(const Key('viewer-info-panel'));
          expect(panel, findsOneWidget);
          expect(tester.getSize(panel).width, 320);

          await tester.tap(
            find.descendant(of: panel, matching: find.text(multi.user.name)),
          );
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsNothing);
          expect(find.text('user-${multi.user.id}'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('accessibleNavigation pins ImageViewerPage chrome open', (
      tester,
    ) async {
      viewerSessionChromeVisible = false;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(() {
        viewerSessionChromeVisible = true;
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      });
      await tester.pumpWidget(
        localizedApp(
          overrides: const [],
          home: const ImageViewerPage(
            urls: ['https://i.pximg.net/img-master/img/1_p0.jpg'],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 / 1'), findsOneWidget);
    });

    testWidgets('Ctrl+S saves active page and B toggles bookmark', (
      tester,
    ) async {
      final log = <String>[];
      final (container, _, _) = await makeWorld(requestLog: log);
      final entity = parseIllust(
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: ImageViewerPage(
            urls: const [
              'https://i.pximg.net/1/original.jpg',
              'https://i.pximg.net/2/original.jpg',
            ],
            entity: entity,
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(downloadManagerProvider).tasks, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();
      expect(log, contains('/v2/illust/bookmark/add'));
    });

    testWidgets(
      'desktop mouse drag pages unzoomed ImageViewerPage and pans while zoomed',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await tester.pumpWidget(
            withStalledImages(
              localizedApp(
                scrollBehavior: const FuncScrollBehavior(),
                home: const ImageViewerPage(
                  urls: [
                    'https://i.pximg.net/1/original.jpg',
                    'https://i.pximg.net/2/original.jpg',
                  ],
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('1 / 2'), findsOneWidget);

          // Unzoomed mouse drag past midpoint turns forward to page 2, then back.
          final startRight = Offset(
            tester.getRect(find.byType(PageView)).right - 60,
            tester.getCenter(find.byType(PageView)).dy,
          );
          final dragForward = await tester.startGesture(
            startRight,
            kind: PointerDeviceKind.mouse,
          );
          await dragForward.moveBy(const Offset(-50, 0));
          await dragForward.moveBy(const Offset(-460, 0));
          await dragForward.up();
          await tester.pumpAndSettle();
          expect(find.text('2 / 2'), findsOneWidget);

          final startLeft = Offset(
            tester.getRect(find.byType(PageView)).left + 60,
            tester.getCenter(find.byType(PageView)).dy,
          );
          final dragBack = await tester.startGesture(
            startLeft,
            kind: PointerDeviceKind.mouse,
          );
          await dragBack.moveBy(const Offset(50, 0));
          await dragBack.moveBy(const Offset(460, 0));
          await dragBack.up();
          await tester.pumpAndSettle();
          expect(find.text('1 / 2'), findsOneWidget);

          // Zoomed in: mouse drag pans the image instead of turning pages.
          final controller0 = tester
              .widget<InteractiveViewer>(
                find.byKey(const ValueKey('viewer-page-0')),
              )
              .transformationController!;
          controller0.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
          await tester.pump();

          final pan = await tester.startGesture(
            tester.getCenter(find.byType(PageView)),
            kind: PointerDeviceKind.mouse,
          );
          await pan.moveBy(const Offset(-50, 0));
          await pan.moveBy(const Offset(-120, 0));
          await pan.up();
          await tester.pumpAndSettle();
          expect(find.text('1 / 2'), findsOneWidget);
          expect(controller0.value.getTranslation().x, lessThan(0));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'ImageViewer exposes bottom bookmark button and Shift+B edit sheet',
      (tester) async {
        final entity = parseIllust(illustJson(42));
        await tester.pumpWidget(
          _host(
            ImageViewerPage(urls: [entity.originalUrlAt(0)!], entity: entity),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('viewer-bookmark-button')), findsOneWidget);
        expect(find.byType(BookmarkSwitchButton), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(find.text('收藏插画'), findsOneWidget);
      },
    );
  });
}
