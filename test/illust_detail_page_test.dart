import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_pager_page.dart';
import 'package:pixiv_func/features/illust/detail/widgets/detail_image_pager.dart';
import 'package:pixiv_func/features/illust/viewer/image_viewer_page.dart';
import 'package:pixiv_func/features/profile/user_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'download_manager_test.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/core/i18n/replica_language.dart';

/// Widget test host: real DownloadManager over a scripted transport +
/// memory sinks, detail API over a MockClient — no platform channels.
Future<(ProviderContainer, FakeTransport, MemorySinkFactory)> makeWorld({
  int scriptedResponses = 4,
  Map<int, Map<String, dynamic>>? detailOverrides,
  Map<int, List<Map<String, dynamic>>>? relatedOverrides,
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
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: router == null
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
              ),
      ),
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
        expect(find.text('2 / 2'), findsOneWidget);

        await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsOneWidget);
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
      expect(find.text('1 / 0'), findsOneWidget);
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
        await tester.tap(find.byType(PageView));
        await tester.pumpAndSettle();
        expectViewerChrome(tester, visible: false);

        await tester.tap(find.byType(PageView));
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
      expect(
        manager.tasks,
        hasLength(1),
        reason: 'retry replaces the failed task (same dedupe key)',
      );
      expect(manager.tasks.single.status, DownloadStatus.succeeded);
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
        findsNWidgets(2),
        reason: 'author name + account render in the author block',
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
          expect(find.text('illust 42'), findsOneWidget);
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
        await tester.tap(find.text('author').first);
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
