import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:flutter/services.dart';

import 'package:pixiv_func/app/layout/two_pane.dart';
import 'package:pixiv_func/app/pixiv_image.dart';
import 'package:pixiv_func/app/person_avatar.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_providers.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/illust/illust_detail_controller.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/app/motion/hero_transition.dart';
import 'package:pixiv_func/app/motion/drag_to_dismiss.dart';
import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_pager_page.dart';
import 'package:pixiv_func/features/illust/detail/widgets/detail_image_pager.dart';
import 'package:pixiv_func/features/illust/detail/ugoira_viewer.dart';
import 'package:pixiv_func/features/illust/viewer/image_viewer_page.dart';
import 'package:pixiv_func/features/profile/user_page.dart';
import 'package:pixiv_func/features/search/tag_search_page.dart';
import 'package:pixiv_func/app/widgets/tag_chips.dart';
import 'package:pixiv_func/core/mute/mute_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'download_manager_test.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/core/i18n/replica_language.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Widget test host: real DownloadManager over a scripted transport +
/// memory sinks, detail API over a MockClient — no platform channels.
Future<(ProviderContainer, FakeTransport, MemorySinkFactory)> makeWorld({
  int scriptedResponses = 4,
  Map<int, Map<String, dynamic>>? detailOverrides,
  Map<int, List<Map<String, dynamic>>>? relatedOverrides,
  Set<String> mutedTags = const {},
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final transport = FakeTransport();
  for (var i = 0; i < scriptedResponses; i++) {
    transport.responses.add(
      ScriptedResponse(
        contentLength: 3,
        chunks: [
          [1, 2, 3],
        ],
      ),
    );
  }
  final sinks = MemorySinkFactory();
  final manager = DownloadManager(transport: transport, sinkFactory: sinks);
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      downloadManagerProvider.overrideWithValue(manager),
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (request) async => throw StateError('refresh must not happen here'),
          ),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) {
          throw StateError('client not wired yet');
        }
        return client;
      }),
      // The page-dims web call degrades to the first-page-ratio fallback
      // here; the merge path itself is covered in the controller tests.
      illustDetailWebClientProvider.overrideWithValue(
        MockClient((request) async => http.Response('unavailable', 403)),
      ),
    ],
  );
  final client = PixivHttpClient(
    client: MockClient((request) async {
      if (request.url.path == '/v1/illust/detail') {
        final id = int.parse(request.url.queryParameters['illust_id']!);
        final override = detailOverrides?[id];
        return okJson({
          'illust':
              override ??
              illustJson(
                42,
                pageCount: 2,
                withMetaPages: true,
                caption: '作品说明文字',
              ),
        });
      }
      if (request.url.path == '/v2/illust/related') {
        final id = int.parse(request.url.queryParameters['illust_id']!);
        return okJson({
          'illusts': relatedOverrides?[id] ?? [],
          'next_url': null,
        });
      }
      // The mute endpoints let tag-menu tests exercise the real
      // MuteStore.toggleTag path (optimistic apply + server edit).
      if (request.url.path == '/v1/mute/list') {
        return okJson({
          'muted_tags': [
            for (final tag in mutedTags) {'tag': tag},
          ],
          'muted_users': <Map<String, dynamic>>[],
          'mute_limit_count': 30,
        });
      }
      if (request.url.path == '/v1/mute/edit') {
        return okJson({});
      }
      return http.Response('unexpected', 404);
    }),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return (container, transport, sinks);
}

http.Response okJson(Map<String, dynamic> json) => http.Response(
  jsonEncode(json),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> pumpDetail(
  WidgetTester tester,
  ProviderContainer container, {
  bool seedStore = true,
  int illustId = 42,
  Locale? locale,
  bool useRouter = false,
  bool reduceMotion = false,
}) async {
  if (seedStore) {
    container.read(illustStoreProvider).mergeAll([
      parseIllust(illustJson(illustId, pageCount: 2, withMetaPages: true)),
    ]);
  }
  final router = useRouter
      ? createPixivRouter(initialLocation: '/recommended/illust/$illustId')
      : null;
  if (router != null) addTearDown(router.dispose);
  Widget app = router == null
      ? MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
            Locale('ja', 'JP'),
            Locale('ru', 'RU'),
          ],
          locale: locale,
          home: IllustDetailPage(illustId: illustId),
        )
      : MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
            Locale('ja', 'JP'),
            Locale('ru', 'RU'),
          ],
          locale: locale,
          routerConfig: router,
        );
  if (reduceMotion) {
    app = MotionScope(reduce: true, child: app);
  }
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: app),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  });
}

Future<void> longPressImage(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(PixivImage).first);
  final gesture = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.up();
  await tester.pump();
}

// Hidden chrome stays mounted (Opacity 0 + ExcludeSemantics — dropping it
// from the tree races the semantics flush). Visibility assertions check
// the bars' opacity and the toggle icon rather than whether finders still
// see the (mounted) counter text.
void expectViewerChrome(WidgetTester tester, {required bool visible}) {
  final bars = tester
      .widgetList<Opacity>(
        find.byWidgetPredicate((w) => w is Opacity && w.alwaysIncludeSemantics),
      )
      .toList();
  expect(bars.length, 2, reason: 'top + bottom chrome bars');
  for (final bar in bars) {
    expect(bar.opacity, visible ? 1.0 : 0.0);
  }
  expect(
    find.byIcon(visible ? Icons.fullscreen : Icons.fullscreen_exit),
    findsOneWidget,
  );
}

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

    testWidgets('shows n / total and honors the initial page', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
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
        );
        await tester.pump();
        // The counter lives in both chrome bars (top title + bottom
        // jump-to-page entry).
        expect(find.text('2 / 2'), findsNWidgets(2));

        await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsNWidgets(2));
      });
    });

    testWidgets('zoom clamps to 0.9–6.0 via InteractiveViewer', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: ImageViewerPage(urls: ['https://i.pximg.net/1/original.jpg']),
          ),
        );
        await tester.pump();

        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(viewer.minScale, ImageViewerPage.minScale);
        expect(viewer.maxScale, ImageViewerPage.maxScale);
        expect(viewer.panEnabled, isFalse);
        expect(ImageViewerPage.minScale, 0.9);
        expect(ImageViewerPage.maxScale, 6.0);
      });
    });

    testWidgets('zoomed viewer keeps vertical gestures for image pan', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const SizedBox.shrink(),
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

    testWidgets('empty URL list renders a placeholder, not a crash', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),

          home: ImageViewerPage(urls: []),
        ),
      );
      await tester.pump();
      expect(find.text('没有可显示的图片'), findsOneWidget);
      // Empty state honesty: no misleading page counter.
      expect(find.text('1 / 0'), findsNothing);
      expect(find.text('第 1 页，共 0 页'), findsNothing);
    }, skip: false);

    testWidgets(
      'U3: the image fills the viewport (tight constraints, not intrinsics)',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: ImageViewerPage(
                urls: ['https://i.pximg.net/1/original.jpg'],
              ),
            ),
          );
          await tester.pump();

          // SizedBox.expand inside the viewer gives the RenderImage tight
          // constraints, so BoxFit.contain has a real viewport to scale
          // against (`Center` alone leaves it at intrinsic size — the bug).
          final viewer = tester.widget<InteractiveViewer>(
            find.byType(InteractiveViewer),
          );
          final expand = viewer.child;
          expect(expand, isA<SizedBox>());
          expect((expand as SizedBox).width, double.infinity);
          expect(expand.height, double.infinity);
        });
      },
    );

    testWidgets('a lone tap hides and restores the chrome', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
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
      'hidden chrome belongs to the session: it survives page turns and '
      'route swaps (revision ①)',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            MaterialApp(
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
          expect(find.text('2 / 2'), findsNWidgets(2));
          expectViewerChrome(tester, visible: false);

          // A route swap (replaceImageViewerPage builds a fresh widget on a
          // new route) keeps the session flag too.
          await tester.pumpWidget(
            MaterialApp(
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
            MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: ImageViewerPage(
                urls: ['https://i.pximg.net/1/original.jpg'],
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
            MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: ImageViewerPage(
                urls: ['https://i.pximg.net/1/original.jpg'],
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

    testWidgets('the page counter opens the jump-to-page sheet', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: ImageViewerPage(
              urls: [
                'https://i.pximg.net/1/original.jpg',
                'https://i.pximg.net/2/original.jpg',
                'https://i.pximg.net/3/original.jpg',
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.text('1 / 3'), findsNWidgets(2));

        await tester.tap(find.text('1 / 3').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('3'));
        await tester.pumpAndSettle();
        expect(find.text('3 / 3'), findsNWidgets(2));
      });
    });

    testWidgets('entity-less viewer renders no save/share/info actions', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: ImageViewerPage(urls: ['https://i.pximg.net/1/original.jpg']),
          ),
        );
        await tester.pump();
        expect(find.byIcon(Icons.download_outlined), findsNothing);
        expect(find.byIcon(Icons.share_outlined), findsNothing);
        expect(find.byIcon(Icons.info_outline), findsNothing);
        // Entity-independent chrome stays available.
        expect(find.byIcon(Icons.fit_screen), findsOneWidget);
        expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      });
    });

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
            MaterialApp(
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
            MaterialApp(
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
          expect(find.text('2 / 2'), findsNWidgets(2));
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pumpAndSettle();
          expect(find.text('1 / 2'), findsNWidgets(2));

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
            MaterialApp(
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
          expect(find.text('1 / 2'), findsNWidgets(2));
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
          expect(find.text('2 / 2'), findsNWidgets(2));
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
        MaterialApp(
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
      'system back with hidden chrome leaves directly — no restore step '
      '(revision \u2461)',
      (tester) async {
        await mockNetworkImagesFor(() async {
          await pumpPushedViewer(tester);

          await tester.tap(find.byType(PageView));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expectViewerChrome(tester, visible: false);

          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsNothing);
        });
      },
    );

    testWidgets('the explicit back button pops even while zoomed', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        await pumpPushedViewer(tester);

        await tester.tap(find.byType(PageView));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();

        await tester.tap(find.byType(BackButton));
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

  group('IllustDetailPage download mode (R4)', () {
    testWidgets(
      'long-press enters explicit selection mode; Done submits only the '
      'selected pages',
      (tester) async {
        final (container, transport, sinks) = await makeWorld();
        await pumpDetail(tester, container);

        // The always-visible Download All entry exists; the selection
        // chrome does not.
        expect(find.byTooltip('Download All'), findsOneWidget);
        expect(find.text('Select pages to download'), findsNothing);
        expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);

        await longPressImage(tester);

        // Mode chrome: title + selected/total count + select-all +
        // done + cancel. Done is disabled while nothing is selected.
        expect(find.text('Select pages to download'), findsOneWidget);
        expect(find.text('0 of 2 selected'), findsOneWidget);
        expect(find.text('Select all'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
              .onPressed,
          isNull,
        );
        // Page 0's badge is the unselected hollow circle (page 1 is below
        // the fold).
        expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

        // Tapping the page badge toggles the selection — nothing downloads
        // yet.
        await mockNetworkImagesFor(() async {
          await tester.tap(find.byIcon(Icons.radio_button_unchecked));
          await tester.pump();
        });
        final manager = container.read(downloadManagerProvider);
        expect(manager.tasks, isEmpty);
        expect(find.byIcon(Icons.check_circle), findsOneWidget);
        expect(find.text('1 of 2 selected'), findsOneWidget);

        // Done submits exactly the selected page and exits the mode.
        await mockNetworkImagesFor(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'Done'));
          await tester.pump();
        });
        expect(manager.tasks, hasLength(1));
        expect(manager.tasks.single.illustId, 42);
        expect(manager.tasks.single.pageIndex, 0);
        expect(
          manager.tasks.single.url.toString(),
          'https://i.pximg.net/42/p0/original.jpg',
        );
        expect(sinks.sinks, hasLength(1));

        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (manager.tasks.single.status != DownloadStatus.running) break;
        }
        expect(manager.tasks.single.status, DownloadStatus.succeeded);
        await tester.pump();
        expect(find.text('Select pages to download'), findsNothing);
        expect(transport.openedUrls, hasLength(1));
      },
    );

    testWidgets('select-all + cancel keeps the mode a pure selection layer', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);

      await longPressImage(tester);
      expect(find.text('0 of 2 selected'), findsOneWidget);

      await tester.tap(find.text('Select all'));
      await tester.pump();
      expect(find.text('2 of 2 selected'), findsOneWidget);

      // Cancel exits the mode without submitting anything.
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Select pages to download'), findsNothing);
      expect(
        container.read(downloadManagerProvider).tasks,
        isEmpty,
        reason: 'cancel never enqueues — submission only happens via Done',
      );
    });

    testWidgets('system back exits the selection mode instead of popping', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, useRouter: true);
      await tester.pump(const Duration(milliseconds: 50));

      await longPressImage(tester);
      expect(find.text('Select pages to download'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 50));
      // The route stays; the mode is gone.
      expect(find.byType(IllustDetailPage), findsOneWidget);
      expect(find.text('Select pages to download'), findsNothing);
      expect(container.read(downloadManagerProvider).tasks, isEmpty);
    });

    testWidgets(
      'a ugoira work never enters selection mode and keeps the export '
      'entry visible (W4 gate: Ugoira)',
      (tester) async {
        final (container, _, _) = await makeWorld(
          detailOverrides: {42: illustJson(42, type: 'ugoira')},
        );
        container.read(illustStoreProvider).mergeAll([
          parseIllust(illustJson(42, type: 'ugoira')),
        ]);
        await pumpDetail(
          tester,
          container,
          seedStore: false,
          locale: const Locale('zh', 'CN'),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byType(UgoiraViewer), findsOneWidget);
        // The always-visible GIF export slot is the ugoira equivalent of
        // the plain download entry (disabled until the asset loads).
        expect(
          find.descendant(
            of: find.byType(UgoiraViewer),
            matching: find.byType(IconButton),
          ),
          findsOneWidget,
        );

        // Ugoira has no pages to select — a long-press must not open the
        // selection chrome.
        await tester.longPress(find.byType(UgoiraViewer));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Select pages to download'), findsNothing);
        expect(find.text('选择要下载的页'), findsNothing);
        expect(container.read(downloadManagerProvider).tasks, isEmpty);
      },
    );

    testWidgets('Download All enqueues every page once', (tester) async {
      final (container, transport, sinks) = await makeWorld(
        scriptedResponses: 4,
      );
      await pumpDetail(tester, container);

      // Always-visible entry — no selection mode needed.
      await mockNetworkImagesFor(() async {
        await tester.tap(find.byTooltip('Download All'));
        await tester.pump();
      });

      final manager = container.read(downloadManagerProvider);
      // Let both transfers drain so no FakeResponse timers leak past the
      // widget-tree disposal.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (manager.tasks.every((t) => t.status == DownloadStatus.succeeded)) {
          break;
        }
      }
      expect(manager.tasks.map((t) => t.pageIndex).toSet(), {0, 1});
      expect(transport.openedUrls, hasLength(2));
      expect(sinks.sinks, hasLength(2));
    });

    testWidgets('failed download shows retry and retry re-enqueues', (
      tester,
    ) async {
      final transport = FakeTransport();
      transport.responses.add(ScriptedResponse(error: Exception('boom')));
      transport.responses.add(
        ScriptedResponse(
          contentLength: 3,
          chunks: [
            [1, 2, 3],
          ],
        ),
      );
      final sinks = MemorySinkFactory();
      final manager = DownloadManager(transport: transport, sinkFactory: sinks);
      final credentials = FakeCredentialStore()
        ..seed(
          '100',
          const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
        );
      final clientRef = <PixivHttpClient?>[null];
      final container = ProviderContainer(
        overrides: [
          downloadManagerProvider.overrideWithValue(manager),
          credentialStoreProvider.overrideWithValue(credentials),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(
              accounts: const [Account(id: '100', userId: 100, name: 'tester')],
              currentId: '100',
            ),
          ),
          oauthServiceProvider.overrideWithValue(
            OAuthService(
              client: MockClient(
                (request) async =>
                    throw StateError('refresh must not happen here'),
              ),
            ),
          ),
          pixivHttpClientProvider.overrideWith((ref) {
            final client = clientRef[0];
            if (client == null) throw StateError('not wired');
            return client;
          }),
        ],
      );
      final client = PixivHttpClient(
        client: MockClient(
          (request) async => okJson({
            'illust': illustJson(42, pageCount: 2, withMetaPages: true),
          }),
        ),
        accountStore: container.read(accountStoreProvider.notifier),
        credentialStore: credentials,
        oauthService: container.read(oauthServiceProvider),
      );
      clientRef[0] = client;
      await container.read(accountStoreProvider.future);
      addTearDown(container.dispose);
      await pumpDetail(tester, container);

      // Enter the selection mode, pick page 0, submit — the task itself
      // then fails asynchronously.
      await longPressImage(tester);
      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.radio_button_unchecked));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pump(const Duration(milliseconds: 100));
      });

      expect(manager.tasks.single.status, DownloadStatus.failed);

      // Re-enter the mode: the failed page surfaces as the error badge.
      // Tapping it selects the page again; Done re-submits and the manager
      // replaces the failed task on the same dedupe key.
      await longPressImage(tester);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.error_outline));
        await tester.pump();
      });
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      await mockNetworkImagesFor(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pump(const Duration(milliseconds: 100));
      });
      expect(manager.tasks.single.status, DownloadStatus.succeeded);
    });

    testWidgets('two-pane layout presents the same selection chrome', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpDetail(tester, container);

      // The two-pane pager forwards the same long-press entry; the
      // selection bar is shared chrome, not a narrow-layout special case.
      await longPressImage(tester);
      expect(find.text('Select pages to download'), findsOneWidget);
      expect(find.text('0 of 2 selected'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsWidgets);

      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
        await tester.pump();
      });
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('1 of 2 selected'), findsOneWidget);

      await mockNetworkImagesFor(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pump();
      });
      final manager = container.read(downloadManagerProvider);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (manager.tasks.every((t) => t.status == DownloadStatus.succeeded)) {
          break;
        }
      }
      expect(manager.tasks.single.pageIndex, 0);
      expect(find.text('Select pages to download'), findsNothing);
    });

    testWidgets('landscape narrow layout presents the same selection chrome', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpDetail(tester, container);

      // Rotated phones stay on the narrow branch; the selection chrome
      // must present identically in the shorter viewport. The page image
      // is taller than the 390px viewport, so the long-press lands on the
      // visible slice rather than the widget's geometric centre.
      final imageRect = tester.getRect(find.byType(PixivImage).first);
      final pressPoint = Offset(
        imageRect.center.dx,
        imageRect.top + (390 - imageRect.top) / 2,
      );
      final gesture = await tester.startGesture(pressPoint);
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pump();
      expect(find.text('Select pages to download'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsWidgets);

      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
        await tester.pump();
      });
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('IllustDetailPage badges & restricted states (R1/R2)', () {
    testWidgets('visible:false detail shows the restricted state', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {42: illustJson(42, visible: false)},
      );
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('该作品已被删除或受限（ID: 42）'), findsOneWidget);
    });

    testWidgets('detail renders badges, tags and summary from the snapshot', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      container.read(illustStoreProvider).mergeAll([
        parseIllust(
          illustJson(
            42,
            pageCount: 2,
            withMetaPages: true,
            xRestrict: 1,
            aiType: 2,
            caption: '作品说明文字',
          ),
        ),
      ]);
      await pumpDetail(tester, container);
      await mockNetworkImagesFor(() async {
        // Scroll the info block into view.
        await tester.scrollUntilVisible(
          find.text('#original'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
      });

      // beta56 detail shows no R-18/AI/page badges (those live on feed
      // cards); it renders author, meta and tags.
      expect(
        find.text('author'),
        findsNWidgets(3),
        reason: 'compact header + author block name + account',
      );
      expect(find.textContaining('800x600'), findsOneWidget);
      expect(find.textContaining('ID: 42'), findsOneWidget);
      expect(find.text('#original'), findsOneWidget);
      expect(find.textContaining('風景'), findsOneWidget);
      expect(find.text('作品说明文字'), findsOneWidget);
      expect(find.text('简介'), findsNothing);
    });

    testWidgets(
      'U5: the card snapshot renders on the very first frame with the '
      'Hero destination present',
      (tester) async {
        final (container, _, _) = await makeWorld();
        final entity = parseIllust(
          illustJson(42, pageCount: 1, width: 800, height: 100),
        );

        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: IllustDetailPage(
                  illustId: 42,
                  initialEntity: entity,
                  heroScope: 'profile:42:bookmarks:illust:public',
                  heroImageUrl: 'https://i.pximg.net/feed/42/medium.jpg',
                ),
              ),
            ),
          );
          // No second pump / settle: this is the AsyncLoading first frame.
          expect(find.byType(ProgressIndicator), findsNothing);
          expect(
            find.byType(Scrollable),
            findsWidgets,
            reason: 'content renders from the card snapshot, not a spinner',
          );
          // Two copies are expected: the persistent compact header carries
          // the title too (C17); the snapshot proves out through either.
          expect(find.text('illust 42'), findsNWidgets(2));
          expect(find.text('author'), findsWidgets);
          expect(
            tester.widget<PixivImage>(find.byType(PixivImage).first).url,
            'https://i.pximg.net/feed/42/medium.jpg',
            reason: 'the Hero target must reuse the exact feed cache key',
          );
          expect(find.byKey(const Key('illust-author-avatar')), findsOneWidget);
          expect(find.byType(PersonAvatar), findsOneWidget);
          expect(
            tester.widget<PersonAvatar>(find.byType(PersonAvatar)).imageUrl,
            isNotNull,
            reason: 'the author avatar provider exists in the first frame',
          );
          // Hero destination exists on the first frame (feed -> detail flight).
          final hero = tester.widget<Hero>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Hero &&
                  widget.tag ==
                      'IllustHero:profile:42:bookmarks:illust:public:42',
            ),
          );
          expect(hero, isNotNull);
          expect(hero.flightShuttleBuilder, illustHeroFlightShuttleBuilder);
        });
      },
    );

    testWidgets('detail artwork keeps the cold-load transition enabled', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);

      final image = tester.widget<PixivImage>(find.byType(PixivImage).first);
      expect(
        image.fade,
        isTrue,
        reason: 'cold detail artwork should not appear abruptly',
      );
    });

    testWidgets(
      'U6: caption renders as rich clickable text, not literal HTML',
      (tester) async {
        final (container, _, _) = await makeWorld(
          detailOverrides: {
            42: illustJson(
              42,
              caption:
                  'line1<br>line2 — <a '
                  'href="https://www.pixiv.net/users/7">author</a> '
                  '&amp; more',
            ),
          },
        );
        await pumpDetail(tester, container, useRouter: true);
        await mockNetworkImagesFor(() async {
          await tester.scrollUntilVisible(
            find.textContaining('line1'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump();
        });

        // The key assertions: no literal `<br />` text, the caption text
        // renders decoded, and tapping an in-app pixiv link pushes a route.
        // ('author' also names the author block, hence .last.)
        expect(find.textContaining('<br>'), findsNothing);
        expect(find.textContaining('line1'), findsOneWidget);
        expect(find.text('author'), findsWidgets);
        expect(find.text('简介'), findsNothing);

        await tester.tap(find.text('author').last);
        await tester.pumpAndSettle();
        expect(
          find.byType(Scaffold).evaluate().length,
          greaterThanOrEqualTo(2),
          reason: 'in-app pixiv link pushes a detail page route',
        );
      },
    );
  });

  group('IllustDetailPage author block & i18n (U9 / C20)', () {
    testWidgets('U9: tapping the author block opens the user page', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, useRouter: true);
      await mockNetworkImagesFor(() async {
        await tester.scrollUntilVisible(
          find.byKey(const Key('illust-author-avatar')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
      });

      expect(find.byType(UserPage), findsNothing);
      await mockNetworkImagesFor(() async {
        // The avatar is the smallest of the three hit areas; the InkWell
        // wraps the whole Row, so a tap on it must reach the same callback.
        await tester.tap(find.byKey(const Key('illust-author-avatar')));
        await tester.pumpAndSettle();
      });
      expect(find.byType(UserPage), findsOneWidget);
    });

    testWidgets('U9: tapping the author name opens the user page too', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, useRouter: true);
      await mockNetworkImagesFor(() async {
        await tester.scrollUntilVisible(
          find.byKey(const Key('illust-author-avatar')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
      });

      await mockNetworkImagesFor(() async {
        // .last — the compact header carries a non-tappable copy first
        // in tree order; the author block's InkWell is the last match.
        await tester.tap(find.text('author').last);
        await tester.pumpAndSettle();
      });
      expect(find.byType(UserPage), findsOneWidget);
    });

    testWidgets('C20: detail copy follows the UI locale', (tester) async {
      const keys = [
        'illustDetailCreateDateUnknown',
        'illustDetailSize',
        'illustDetailNotFound',
        'illustDetailLoadFailed',
      ];

      for (final language in [ReplicaLanguage.jaJP, ReplicaLanguage.enUS]) {
        final (container, _, _) = await makeWorld();
        await pumpDetail(
          tester,
          container,
          locale: switch (language) {
            ReplicaLanguage.jaJP => const Locale('ja', 'JP'),
            _ => const Locale('en', 'US'),
          },
        );
        await mockNetworkImagesFor(() async {
          await tester.scrollUntilVisible(
            find.text('#original'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump();
        });

        // The size row is the one always-present interpolated string.
        expect(
          find.text(switch (language) {
            ReplicaLanguage.jaJP => 'サイズ：800x600',
            _ => 'Size: 800x600',
          }),
          findsOneWidget,
          reason: 'size row must render in ${language.tag}',
        );
        // No zh fallback leaks through for any of the migrated keys.
        for (final key in keys) {
          expect(
            find.textContaining('尺寸：800x600'),
            findsNothing,
            reason: '$key must not fall back to zh under ${language.tag}',
          );
        }
      }
    });
  });

  group('Related works (official detail-page section)', () {
    testWidgets('renders the section title and related tiles', (tester) async {
      final (container, _, _) = await makeWorld(
        relatedOverrides: {
          42: [illustJson(901, pageCount: 1), illustJson(902, pageCount: 1)],
        },
      );
      await pumpDetail(tester, container, useRouter: true);
      // The section is a lazy sliver below the info block: scroll down so
      // it builds, then let the related page resolve.
      await mockNetworkImagesFor(() async {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1400),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1400),
        );
        await tester.pump(const Duration(milliseconds: 200));
      });

      // Section appears below the caption/tags with the official title.
      expect(find.text('Related works'), findsOneWidget);
      expect(find.text('illust 901'), findsOneWidget);
      expect(find.text('illust 902'), findsOneWidget);
    });

    testWidgets('tapping a related tile opens its own detail page', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        relatedOverrides: {
          42: [illustJson(901, pageCount: 1)],
        },
      );
      await pumpDetail(tester, container, useRouter: true);
      await mockNetworkImagesFor(() async {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1400),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1400),
        );
        await tester.pump(const Duration(milliseconds: 200));
        // Ensure the tile is visible before tapping (it may sit below the
        // fold after the second drag).
        await tester.scrollUntilVisible(
          find.text('illust 901'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump(const Duration(milliseconds: 50));
        // Tap the related card's image area (IllustCard's onTap covers the
        // image; the title row below is not clickable).
        final relatedHero = find.byWidgetPredicate(
          (w) => w is Hero && '${w.tag}'.contains('901'),
        );
        await tester.tapAt(tester.getRect(relatedHero).center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 350));
      });
      // The related section is a feed grid, so the tile opens the
      // work-to-work pager across the related list (Shaft parity) — the
      // pushed route is a pager whose landing work is 901.
      // (skipOffstage: the freshly pushed route is still in transition.)
      expect(find.byType(IllustDetailPagerPage), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 901,
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('empty related list hides the whole section', (tester) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);
      await mockNetworkImagesFor(() async {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1400),
        );
        await tester.pump(const Duration(milliseconds: 200));
      });
      expect(find.text('Related works'), findsNothing);
    });
  });

  group('narrow compact header (C17)', () {
    testWidgets('renders title/author/page context and the info jump on narrow '
        'surfaces', (tester) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

      // Header shows the work context while the body is still on page 1.
      expect(find.text('illust 42'), findsOneWidget);
      expect(find.text('author'), findsOneWidget);
      expect(find.text('第 1 页，共 2 页'), findsOneWidget);
      expect(find.byTooltip('跳到作品信息区'), findsOneWidget);
    });

    testWidgets('the info button scrolls InfoBlock into view', (tester) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();

      // InfoBlock's caption sits below the fold — not built yet.
      expect(find.text('作品说明文字'), findsNothing);

      await tester.tap(find.byTooltip('跳到作品信息区'));
      await tester.pumpAndSettle();
      expect(find.text('作品说明文字'), findsOneWidget);
      expect(
        tester.getRect(find.text('作品说明文字')).top,
        lessThan(tester.view.physicalSize.height),
      );
    });

    testWidgets('the header is absent in the two-pane layout', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

      expect(find.byType(TwoPane), findsOneWidget);
      expect(find.byTooltip('跳到作品信息区'), findsNothing);
      expect(find.text('第 1 页，共 2 页'), findsNothing);
    });

    testWidgets('the header is absent in the restricted state', (tester) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {42: illustJson(42, visible: false)},
      );
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('该作品已被删除或受限（ID: 42）'), findsOneWidget);
      expect(find.byTooltip('跳到作品信息区'), findsNothing);
    });

    testWidgets(
      'a long multi-page work keeps title/author pinned and the counter '
      'tracks the scrolled page (W4 gate: 长多页)',
      (tester) async {
        final (container, _, _) = await makeWorld(
          detailOverrides: {
            42: illustJson(42, pageCount: 6, withMetaPages: true),
          },
        );
        container.read(illustStoreProvider).mergeAll([
          parseIllust(illustJson(42, pageCount: 6, withMetaPages: true)),
        ]);
        await pumpDetail(
          tester,
          container,
          seedStore: false,
          locale: const Locale('zh', 'CN'),
        );

        expect(find.text('illust 42'), findsOneWidget);
        expect(find.text('第 1 页，共 6 页'), findsOneWidget);

        // Scroll two screenfuls down the page column — the pinned header
        // stays put and the counter leaves page 1 behind.
        for (var i = 0; i < 3; i++) {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -500),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();

        expect(find.text('illust 42'), findsOneWidget);
        expect(find.text('author'), findsWidgets);
        expect(find.text('第 1 页，共 6 页'), findsNothing);
        expect(find.textContaining('共 6 页'), findsOneWidget);
      },
    );
  });

  group('tag action menu (R3)', () {
    /// The tag row sits below the image slivers — scroll it into view
    /// before the long-press (finders cannot reach unbuilt sliver
    /// children). The predicate finder stays single-valued ('original' is
    /// the fixture's first tag) without `.first`, which would throw while
    /// the row is still unbuilt mid-scroll.
    Finder originalTagChip() =>
        find.byWidgetPredicate((w) => w is TagChip && w.label == 'original');

    Future<void> longPressFirstTag(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        originalTagChip(),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.longPress(originalTagChip());
      await tester.pumpAndSettle();
    }

    void mockClipboard(
      List<String> captured,
      TestWidgetsFlutterBinding binding,
    ) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            captured.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    testWidgets(
      'long-press opens the menu with search/copy/mute/batch entries and '
      'copy lands on the clipboard',
      (tester) async {
        final (container, _, _) = await makeWorld();
        final captured = <String>[];
        mockClipboard(captured, tester.binding);
        await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

        await longPressFirstTag(tester);
        expect(find.text('搜索该标签'), findsOneWidget);
        expect(find.text('复制标签名'), findsOneWidget);
        expect(find.text('屏蔽该标签'), findsOneWidget);
        expect(find.text('批量屏蔽标签'), findsOneWidget);

        await tester.tap(find.text('复制标签名'));
        await tester.pumpAndSettle();
        expect(captured, ['original']);
        expect(find.text('已复制标签'), findsOneWidget);
      },
    );

    testWidgets('mute writes MuteStore.tags and a muted tag offers 解除屏蔽', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

      // Mute: the menu item writes through the real MuteStore (the
      // mock client answers /v1/mute/edit with 200).
      await longPressFirstTag(tester);
      await tester.tap(find.text('屏蔽该标签'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(muteStoreProvider).tags, contains('original'));

      // The same long-press on a muted tag names the action 解除屏蔽.
      await longPressFirstTag(tester);
      expect(find.text('解除屏蔽该标签'), findsOneWidget);
      await tester.tap(find.text('解除屏蔽该标签'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        container.read(muteStoreProvider).tags,
        isNot(contains('original')),
      );
    });

    testWidgets(
      'the batch entry flips block mode and search opens the tag feed',
      (tester) async {
        final (container, _, _) = await makeWorld();
        await pumpDetail(
          tester,
          container,
          locale: const Locale('zh', 'CN'),
          useRouter: true,
        );

        // 批量屏蔽标签 → chips enter block mode.
        await longPressFirstTag(tester);
        await tester.tap(find.text('批量屏蔽标签'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TagChip>(find.byType(TagChip).first).blockMode,
          isTrue,
        );

        // 搜索该标签 → pushes the tag feed route over the detail page.
        await longPressFirstTag(tester);
        await tester.tap(find.text('搜索该标签'));
        await tester.pumpAndSettle();
        expect(find.byType(TagSearchPage), findsOneWidget);
      },
    );
  });

  group('two-pane layout (width >= 1200)', () {
    testWidgets('splits into image pager and meta column', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);
      expect(find.byType(TwoPane), findsOneWidget);
      expect(find.byType(DetailImagePager), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);
      // Page indicator and the meta column's info block both render.
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('作品说明文字'), findsOneWidget);
    });

    testWidgets('arrow keys page the image pane', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1 / 2'), findsOneWidget);
    });

    testWidgets('reduced motion lands the key page-turn in one frame', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, reduceMotion: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      // The resolved zero duration lands the target page on the next frame —
      // a still-animating pager would still report '1 / 2' here.
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('narrow surface keeps the single scroll view', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);
      expect(find.byType(TwoPane), findsNothing);
      expect(find.byType(DetailImagePager), findsNothing);
      expect(find.byType(CustomScrollView), findsOneWidget);
    });
  });
}
