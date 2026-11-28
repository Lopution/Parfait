import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/navigation/viewer_session.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';

import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/waits.dart';

double _scale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

void main() {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  group('ImageViewerPage (R3)', () {
    setUp(debugResetViewerSession);

    const twoPages = [
      'https://i.pximg.net/1/original.jpg',
      'https://i.pximg.net/2/original.jpg',
    ];

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

    testWidgets('the save action submits the active page', (tester) async {
      final (container, _, _) = await makeWorld();
      final entity = parseIllust(
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: ImageViewerPage(urls: twoPages, entity: entity),
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
          home: ImageViewerPage(urls: twoPages, entity: entity),
        ),
      );
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.download));
      await tester.pump();

      final manager = container.read(downloadManagerProvider);
      await pumpUntil(
        tester,
        () => manager.tasks.every((t) => t.status == DownloadStatus.succeeded),
        frames: 30,
      );
      expect(manager.tasks.single.status, DownloadStatus.succeeded);
      await tester.pump();
      expect(find.byIcon(UiIcons.checkCircle), findsOneWidget);
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

    testWidgets('a page decodes a preview until zoomed, then the whole file', (
      tester,
    ) async {
      await pumpViewer(tester, urls: [twoPages.first]);
      PixivImage page() => tester.widget<PixivImage>(find.byType(PixivImage));
      final preview = ImageViewerPage.previewDecodeWidth(
        tester.element(find.byType(PageView)),
      );
      expect(page().memCacheWidth, preview);
      expect(page().transitionKey, isNotNull);

      final zoom = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      for (final (scale, width) in [
        (1.4, preview),
        (ImageViewerPage.fullDecodeScale, null),
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
      expect(_scale(tester), closeTo(1.0, 0.01));
      expect(find.byType(ImageViewerPage), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerPage), findsNothing);
    });

    testWidgets(
      'the zoom gate still intercepts after a route swap rebuilds the '
      'viewer state',
      (tester) async {
        await pumpPushedViewer(tester);

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
          home: ImageViewerPage(urls: twoPages, entity: entity),
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
  });
}
