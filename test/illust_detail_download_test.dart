import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/detail/ugoira_viewer.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/detail_world.dart';
import 'helpers/download_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';

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

  group('IllustDetailPage download mode (R4)', () {
    testWidgets('download feedback opens tasks after the detail is disposed', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final (container, _, _) = await makeWorld();
        await pumpDetail(tester, container, useRouter: true);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Download All'));
        await tester.pumpAndSettle();
        expect(container.read(downloadManagerProvider).tasks, hasLength(2));
        expect(find.text('View'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(IllustDetailPage), findsNothing);
        await tester.tap(find.text('View'));
        await tester.pumpAndSettle();
        expect(find.byType(DownloadTasksPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('multi-page works expose an explicit selection action', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);

      // The selection entry lives in the ⋮ menu with its text label.
      await openDetailMenu(tester);
      await tester.tap(find.text('Select pages to download'));
      await tester.pumpAndSettle();

      expect(selectionCount(tester), isNotNull);
      expect(selectionCount(tester), '0');
      expect(find.byTooltip('Select all'), findsOneWidget);
      expect(find.byTooltip('Cancel'), findsOneWidget);
    });

    testWidgets(
      'long-press enters explicit selection mode; Done submits only the '
      'selected pages',
      (tester) async {
        final (container, transport, sinks) = await makeWorld();
        await pumpDetail(tester, container);

        // The always-visible Download All entry exists; the selection
        // chrome does not.
        expect(find.byTooltip('Download All'), findsOneWidget);
        expect(selectionCount(tester), isNull);
        expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);

        await longPressImage(tester);

        // The shared selection bar: count, select all, download, close.
        // Download is disabled while nothing is selected.
        expect(selectionCount(tester), isNotNull);
        expect(selectionCount(tester), '0');
        expect(find.byTooltip('Select all'), findsOneWidget);
        expect(find.byTooltip('Cancel'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: downloadSelectedButton,
                  matching: find.byType(IconButton),
                ),
              )
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
        expect(selectionCount(tester), '1');

        // Download submits exactly the selected page and exits the mode.
        await mockNetworkImagesFor(() async {
          await tester.tap(downloadSelectedButton);
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
        expect(selectionCount(tester), isNull);
        expect(transport.openedUrls, hasLength(1));
      },
    );

    testWidgets('select-all + cancel keeps the mode a pure selection layer', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);

      await longPressImage(tester);
      expect(selectionCount(tester), '0');

      await tester.tap(find.byTooltip('Select all'));
      await tester.pump();
      expect(selectionCount(tester), '2');

      // Cancel exits the mode without submitting anything.
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pump();
      expect(selectionCount(tester), isNull);
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
      expect(selectionCount(tester), isNotNull);

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 50));
      // The route stays; the mode is gone.
      expect(find.byType(IllustDetailPage), findsOneWidget);
      expect(selectionCount(tester), isNull);
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

        // The ⋮ menu carries share + the artwork-info jump only — ugoira
        // has no pages to select.
        await openDetailMenu(tester, tooltip: '显示菜单');
        expect(find.text('分享'), findsOneWidget);
        expect(find.text('跳到作品信息区'), findsOneWidget);
        expect(find.text('选择要下载的页'), findsNothing);
        // Dismiss the menu before the long-press checks.
        await tester.tapAt(const Offset(10, 400));
        await tester.pumpAndSettle();

        // Ugoira has no pages to select — a long-press must not open the
        // selection chrome.
        await tester.longPress(find.byType(UgoiraViewer));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(selectionCount(tester), isNull);
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
        await tester.tap(downloadSelectedButton);
        await tester.pump(const Duration(milliseconds: 100));
      });

      expect(manager.tasks.single.status, DownloadStatus.failed);

      // Re-enter the mode: the failed page surfaces as the error badge.
      // Tapping it selects the page again; Done re-submits and the manager
      // replaces the failed task on the same dedupe key.
      await longPressImage(tester);
      final pageError = find.descendant(
        of: find.byType(DetailPageImage),
        matching: find.byIcon(Icons.error_outline),
      );
      expect(pageError, findsOneWidget);
      // The selection mode brings its own download; the bar steps aside.
      expect(find.byType(DetailActionBar), findsNothing);

      await mockNetworkImagesFor(() async {
        await tester.tap(pageError);
        await tester.pump();
      });
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byIcon(Icons.check_circle),
          matching: find.byType(StateIconSwitcher),
        ),
        findsOneWidget,
      );

      await mockNetworkImagesFor(() async {
        await tester.tap(downloadSelectedButton);
        await tester.pump(const Duration(milliseconds: 100));
      });
      expect(manager.tasks.single.status, DownloadStatus.succeeded);
    });
  });
}
