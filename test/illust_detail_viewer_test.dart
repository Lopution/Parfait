import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:flutter/services.dart';

import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/image_network.dart';
import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'helpers/prompt_host.dart';

import 'helpers/illust_detail_page_support.dart';

void main() {
  installMemoryPreferences();

  // The detail page tracks the visible image page through
  // VisibilityDetector (compact-header page counter); a zero interval
  // defers updates to post-frame callbacks so no Timer outlives a test.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  group('ImageViewerPage (R3)', () {
    // The chrome toggle is session-level state (revision ①): reset it
    // between tests so one test's hidden chrome cannot leak into the next.
    setUp(debugResetViewerSession);

    testWidgets('zoomed viewer keeps vertical gestures for image pan', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          withStalledImages(
            MaterialApp(
              builder: promptHostBuilder,
              navigatorKey: navigatorKey,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
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
    });

    testWidgets('a lone tap hides and restores the chrome', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          withStalledImages(
            MaterialApp(
              builder: promptHostBuilder,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: ImageViewerPage(
                urls: [
                  'https://i.pximg.net/1/original.jpg',
                  'https://i.pximg.net/2/original.jpg',
                ],
                initialPage: 1,
              ),
            ),
          ),
        );
        await tester.pump();
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
    });

    testWidgets(
      'scrubbing jumps to the target page without building crossed pages',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),
                home: ImageViewerPage(
                  urls: [
                    for (var i = 0; i < 5; i++)
                      'https://i.pximg.net/$i/original.jpg',
                  ],
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.byKey(const ValueKey('viewer-page-2')), findsNothing);

          final scrubber = find.byKey(const Key('viewer-page-scrubber'));
          expect(scrubber, findsOneWidget);
          await tester.drag(scrubber, const Offset(320, 0));
          await tester.pumpAndSettle();

          expect(find.text('5 / 5'), findsOneWidget);
          expect(find.byKey(const ValueKey('viewer-page-2')), findsNothing);
        });
      },
    );

    testWidgets(
      'hidden chrome belongs to the session: it survives page turns and '
      'route swaps (revision ①)',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: ImageViewerPage(
                  urls: [
                    'https://i.pximg.net/1/original.jpg',
                    'https://i.pximg.net/2/original.jpg',
                  ],
                ),
              ),
            ),
          );
          await tester.pump();

          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: false);

          // Page turn — the chrome stays hidden.
          await tester.fling(
            find.byType(PageView),
            const Offset(-300, 0),
            1000,
          );
          await tester.pumpAndSettle();
          expect(find.text('2 / 2'), findsOneWidget);
          expectViewerChrome(tester, visible: false);

          // A route swap (replaceImageViewerPage builds a fresh widget on a
          // new route) keeps the session flag too.
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: ImageViewerPage(
                  urls: [
                    'https://i.pximg.net/1/original.jpg',
                    'https://i.pximg.net/2/original.jpg',
                  ],
                  initialPage: 1,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: false);
        });
      },
    );

    testWidgets(
      'double-tap runs the fit<->2.5 zoom cycle without toggling chrome',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: ImageViewerPage(
                  urls: ['https://i.pximg.net/1/original.jpg'],
                ),
              ),
            ),
          );
          await tester.pump();

          double scale() => tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController!
              .value
              .getMaxScaleOnAxis();
          expect(scale(), 1.0);

          // fit → 2.5. The second tap must land inside the double-tap
          // window (>= kDoubleTapMinTime, < kDoubleTapTimeout).
          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tap(find.byType(PageView));
          await tester.pumpAndSettle();
          expect(scale(), closeTo(2.5, 0.01));
          expectViewerChrome(tester, visible: true);

          // 2.5 → fit
          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tap(find.byType(PageView));
          await tester.pumpAndSettle();
          expect(scale(), closeTo(1.0, 0.01));
        });
      },
    );

    testWidgets(
      'tap/double-tap disambiguation: tap waits out the window, double-tap '
      'zooms, the next tap toggles chrome again',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: ImageViewerPage(
                  urls: ['https://i.pximg.net/1/original.jpg'],
                ),
              ),
            ),
          );
          await tester.pump();

          double scale() => tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController!
              .value
              .getMaxScaleOnAxis();

          // A lone tap resolves only after the double-tap window; pump past
          // ~kDoubleTapTimeout before asserting the chrome toggle.
          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: false);
          expect(scale(), 1.0);

          // Double-tap zooms without touching the chrome.
          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tap(find.byType(PageView));
          await tester.pumpAndSettle();
          expect(scale(), closeTo(2.5, 0.01));
          expectViewerChrome(tester, visible: false);

          // The following lone tap toggles chrome again — the disambiguation
          // resolved cleanly instead of swallowing the tap.
          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: true);
        });
      },
    );

    testWidgets('the save action submits the active page', (tester) async {
      final (container, transport, sinks) = await makeWorld();
      final entity = parseIllust(
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: promptHostBuilder,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: ImageViewerPage(
                urls: [
                  'https://i.pximg.net/1/original.jpg',
                  'https://i.pximg.net/2/original.jpg',
                ],
                entity: entity,
              ),
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
    });

    testWidgets('the save icon tracks the live download state (manager events '
        'subscription)', (tester) async {
      final (container, _, _) = await makeWorld();
      final entity = parseIllust(
        illustJson(42, pageCount: 2, withMetaPages: true),
      );
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: promptHostBuilder,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: ImageViewerPage(
                urls: [
                  'https://i.pximg.net/1/original.jpg',
                  'https://i.pximg.net/2/original.jpg',
                ],
                entity: entity,
              ),
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
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (manager.tasks.every(
            (t) => t.status == DownloadStatus.succeeded,
          )) {
            break;
          }
        }
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
    });

    testWidgets(
      'explicit exits pop imperatively even while zoomed (Esc + back button)',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),
                home: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ImageViewerPage(
                          urls: ['https://i.pximg.net/1/original.jpg'],
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
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
          expect(find.text('open'), findsOneWidget);
        });
      },
    );

    testWidgets(
      'keyboard: arrows page, +/- zooms, 0 resets, F toggles chrome',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: ImageViewerPage(
                  urls: [
                    'https://i.pximg.net/1/original.jpg',
                    'https://i.pximg.net/2/original.jpg',
                  ],
                ),
              ),
            ),
          );
          await tester.pump();

          double scale() => tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController!
              .value
              .getMaxScaleOnAxis();

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
          expect(scale(), greaterThan(1.0));
          await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
          await tester.pumpAndSettle();
          expect(scale(), closeTo(1.0, 0.01));

          // F toggles the chrome.
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: false);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: true);
        });
      },
    );

    testWidgets(
      'mouse wheel zooms the active page; shift+wheel turns the page',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            withStalledImages(
              MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: ImageViewerPage(
                  urls: [
                    'https://i.pximg.net/1/original.jpg',
                    'https://i.pximg.net/2/original.jpg',
                  ],
                ),
              ),
            ),
          );
          await tester.pump();
          final center = tester.getCenter(find.byType(PageView));

          double scale() => tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController!
              .value
              .getMaxScaleOnAxis();

          // Wheel-up zooms in around the pointer; wheel-down zooms back.
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: center,
              scrollDelta: const Offset(0, -120),
            ),
          );
          await tester.pumpAndSettle();
          expect(scale(), greaterThan(1.0));
          // The pager must not consume the wheel event — still page 1.
          expect(find.text('1 / 2'), findsOneWidget);
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: center,
              scrollDelta: const Offset(0, 120),
            ),
          );
          await tester.pumpAndSettle();
          expect(scale(), closeTo(1.0, 0.01));

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
        });
      },
    );

    // System-back tests need the viewer pushed as a *second* route —
    // `handlePopRoute` -> maybePop refuses to pop the last route (the OS
    // would take over), so a stub home sits underneath.
    Future<void> pumpPushedViewer(
      WidgetTester tester, {
      List<String> urls = const ['https://i.pximg.net/1/original.jpg'],
    }) async {
      await tester.pumpWidget(
        withStalledImages(
          MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
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

    testWidgets('system back while zoomed resets to fit and keeps the route', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        await pumpPushedViewer(tester);

        double scale() => tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis();

        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();
        expect(scale(), greaterThan(1.0));

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        // Zoom reset; the route stayed.
        expect(scale(), closeTo(1.0, 0.01));
        expect(find.byType(ImageViewerPage), findsOneWidget);

        // Now at fit — the next system back leaves the route.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsNothing);
      });
    });

    testWidgets(
      'the zoom gate still intercepts after a route swap rebuilds the '
      'viewer state',
      (tester) async {
        await mockNetworkImagesFor(() async {
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

          double scale() => tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController!
              .value
              .getMaxScaleOnAxis();

          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tap(find.byType(PageView));
          await tester.pumpAndSettle();
          expect(scale(), greaterThan(1.0));

          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(scale(), closeTo(1.0, 0.01));
          expect(find.byType(ImageViewerPage), findsOneWidget);
        });
      },
    );
  });
}
