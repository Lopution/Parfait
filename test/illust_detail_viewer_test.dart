import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/services.dart';

import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';

import 'helpers/image_network.dart';
import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'helpers/prompt_host.dart';

import 'helpers/illust_detail_page_support.dart';
import 'helpers/localized_app.dart';
import 'helpers/waits.dart';

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
      await tester.tap(find.byIcon(Icons.download_outlined));
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
      await tester.tap(find.byIcon(Icons.download_outlined));
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
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      // The exist state also disables the button (detail-page badge
      // semantics carried over).
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.check_circle),
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
  });
}
