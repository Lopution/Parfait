import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_providers.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';
import 'package:pixiv_func/features/illust/viewer/image_viewer_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'download_manager_test.dart';
import 'helpers/illust_fixtures.dart';

/// Widget test host: real DownloadManager over a scripted transport +
/// memory sinks, detail API over a MockClient — no platform channels.
Future<(ProviderContainer, FakeTransport, MemorySinkFactory)> makeWorld({
  int scriptedResponses = 4,
  Map<int, Map<String, dynamic>>? detailOverrides,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final transport = FakeTransport();
  for (var i = 0; i < scriptedResponses; i++) {
    transport.responses.add(
      ScriptedResponse(
        contentLength: 3,
        chunks: [
          [1, 2, 3]
        ],
      ),
    );
  }
  final sinks = MemorySinkFactory();
  final manager = DownloadManager(
    transport: transport,
    sinkFactory: sinks,
  );
  final credentials = _FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(overrides: [
    downloadManagerProvider.overrideWithValue(manager),
    credentialStoreProvider.overrideWithValue(credentials),
    accountMetadataRepositoryProvider
        .overrideWithValue(_FakeMetadataRepository()),
    oauthServiceProvider.overrideWithValue(
      OAuthService(
        client: MockClient((request) async =>
            throw StateError('refresh must not happen here')),
      ),
    ),
    pixivHttpClientProvider.overrideWith((ref) {
      final client = clientRef[0];
      if (client == null) {
        throw StateError('client not wired yet');
      }
      return client;
    }),
  ]);
  final client = PixivHttpClient(
    client: MockClient((request) async {
      if (request.url.path == '/v1/illust/detail') {
        final id = int.parse(request.url.queryParameters['illust_id']!);
        final override = detailOverrides?[id];
        return okJson({
          'illust': override ?? illustJson(42, pageCount: 2, withMetaPages: true),
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

class _FakeCredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _FakeMetadataRepository implements AccountMetadataRepository {
  @override
  Future<AccountMetadataSnapshot> load() async =>
      const AccountMetadataSnapshot(
        accounts: [Account(id: '100', userId: 100, name: 'tester')],
        currentId: '100',
      );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

Future<void> pumpDetail(
  WidgetTester tester,
  ProviderContainer container, {
  bool seedStore = true,
  int illustId = 42,
}) async {
  if (seedStore) {
    container.read(illustStoreProvider).mergeAll([
      parseIllust(
        illustJson(illustId, pageCount: 2, withMetaPages: true),
      ),
    ]);
  }
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: IllustDetailPage(illustId: illustId)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  });
}

Future<void> longPressImage(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(AspectRatio).first);
  final gesture = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.up();
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('ImageViewerPage (R3)', () {
    testWidgets('shows n / total and honors the initial page', (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
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

        await tester.fling(
          find.byType(PageView),
          const Offset(300, 0),
          1000,
        );
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsOneWidget);
      });
    });

    testWidgets('zoom clamps to 0.9–6.0 via InteractiveViewer',
        (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ImageViewerPage(
              urls: ['https://i.pximg.net/1/original.jpg'],
            ),
          ),
        );
        await tester.pump();

        final viewer =
            tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        expect(viewer.minScale, ImageViewerPage.minScale);
        expect(viewer.maxScale, ImageViewerPage.maxScale);
        expect(ImageViewerPage.minScale, 0.9);
        expect(ImageViewerPage.maxScale, 6.0);
      });
    });

    testWidgets('empty URL list renders a placeholder, not a crash',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: ImageViewerPage(urls: [])),
      );
      await tester.pump();
      expect(find.text('没有可显示的图片'), findsOneWidget);
      expect(find.text('1 / 0'), findsOneWidget);
    },
        skip: false);

    testWidgets(
        'U3: the image fills the viewport (tight constraints, not intrinsics)',
        (tester) async {
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          MaterialApp(
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
    });
  });

  group('IllustDetailPage download mode (R4)', () {
    testWidgets('long-press enters download mode with per-page actions',
        (tester) async {
      final (container, transport, sinks) = await makeWorld();
      await pumpDetail(tester, container);

      expect(find.byIcon(Icons.file_download_outlined), findsNothing);

      await longPressImage(tester);

      // Page 0 badge on screen + Download All app bar action (page 1 is
      // below the fold).
      expect(find.byIcon(Icons.file_download_outlined), findsNWidgets(2));

      // Tap the first page badge → real queued task via the manager.
      final manager = container.read(downloadManagerProvider);
      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.file_download_outlined).first);
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
      // The badge flips only after the widget rebuilds reading the manager.
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(transport.openedUrls, hasLength(1));
    });

    testWidgets('Download All enqueues every page once', (tester) async {
      final (container, transport, sinks) =
          await makeWorld(scriptedResponses: 4);
      await pumpDetail(tester, container);

      await longPressImage(tester);
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

    testWidgets('failed download shows retry and retry re-enqueues',
        (tester) async {
      final transport = FakeTransport();
      transport.responses.add(ScriptedResponse(error: Exception('boom')));
      transport.responses.add(
        ScriptedResponse(
          contentLength: 3,
          chunks: [
            [1, 2, 3]
          ],
        ),
      );
      final sinks = MemorySinkFactory();
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: sinks,
      );
      final credentials = _FakeCredentialStore()
        ..seed(
          '100',
          const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
        );
      final clientRef = <PixivHttpClient?>[null];
      final container = ProviderContainer(overrides: [
        downloadManagerProvider.overrideWithValue(manager),
        credentialStoreProvider.overrideWithValue(credentials),
        accountMetadataRepositoryProvider
            .overrideWithValue(_FakeMetadataRepository()),
        oauthServiceProvider.overrideWithValue(
          OAuthService(
            client: MockClient((request) async =>
                throw StateError('refresh must not happen here')),
          ),
        ),
        pixivHttpClientProvider.overrideWith((ref) {
          final client = clientRef[0];
          if (client == null) throw StateError('not wired');
          return client;
        }),
      ]);
      final client = PixivHttpClient(
        client: MockClient((request) async => okJson({
              'illust':
                  illustJson(42, pageCount: 2, withMetaPages: true),
            })),
        accountStore: container.read(accountStoreProvider.notifier),
        credentialStore: credentials,
        oauthService: container.read(oauthServiceProvider),
      );
      clientRef[0] = client;
      await container.read(accountStoreProvider.future);
      addTearDown(container.dispose);
      await pumpDetail(tester, container);

      await longPressImage(tester);
      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.file_download_outlined).first);
        await tester.pump(const Duration(milliseconds: 100));
      });

      expect(manager.tasks.single.status, DownloadStatus.failed);
      // Error state still shows the download icon (tap = retry).
      expect(find.byIcon(Icons.file_download_outlined), findsNWidgets(2));

      await mockNetworkImagesFor(() async {
        await tester.tap(find.byIcon(Icons.file_download_outlined).first);
        await tester.pump(const Duration(milliseconds: 100));
      });
      expect(manager.tasks, hasLength(1),
          reason: 'retry replaces the failed task (same dedupe key)');
      expect(manager.tasks.single.status, DownloadStatus.succeeded);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('IllustDetailPage badges & restricted states (R1/R2)', () {
    testWidgets('visible:false detail shows the restricted state',
        (tester) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {42: illustJson(42, visible: false)},
      );
      await pumpDetail(tester, container);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('删除或受限'), findsOneWidget);
    });

    testWidgets('detail renders badges, tags and summary from the snapshot',
        (tester) async {
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
      expect(find.text('author'), findsNWidgets(2),
          reason: 'author name + account render in the author block');
      expect(find.textContaining('800x600'), findsOneWidget);
      expect(find.textContaining('ID: 42'), findsOneWidget);
      expect(find.text('#original'), findsOneWidget);
      expect(find.textContaining('風景'), findsOneWidget);
      expect(find.text('作品说明文字'), findsNothing,
          reason: 'caption collapses until 简介 tapped');
      await tester.tap(find.text('简介'));
      await tester.pump();
      expect(find.text('作品说明文字'), findsOneWidget);
    });

    testWidgets(
        'U5: the store snapshot renders on the very first frame with the '
        'Hero destination present', (tester) async {
      final (container, _, _) = await makeWorld();
      // Feed already placed the entity in the store before navigation.
      final entity = parseIllust(illustJson(42, pageCount: 2));
      container.read(illustStoreProvider).mergeAll([entity]);

      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: IllustDetailPage(illustId: 42)),
          ),
        );
        // No second pump / settle: this is the AsyncLoading first frame.
        expect(find.byType(ProgressIndicator), findsNothing);
        expect(
          find.byType(Scrollable),
          findsWidgets,
          reason: 'content renders from the store snapshot, not a spinner',
        );
        // Hero destination exists on the first frame (feed -> detail flight).
        final hero = tester.widget<Hero>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Hero && widget.tag == 'IllustHero-42',
          ),
        );
        expect(hero, isNotNull);
      });
    });

    testWidgets(
        'U6: caption renders as rich clickable text, not literal HTML',
        (tester) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(
            42,
            caption: 'line1<br>line2 — <a '
                'href="https://www.pixiv.net/users/7">author</a> '
                '&amp; more',
          ),
        },
      );
      await pumpDetail(tester, container);
      await mockNetworkImagesFor(() async {
        await tester.scrollUntilVisible(
          find.text('简介'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('简介'));
        await tester.pump();
      });

      // The key assertions: no literal `<br />` text, the caption text
      // renders decoded, and tapping an in-app pixiv link pushes a route.
      // ('author' also names the author block, hence .last.)
      expect(find.textContaining('<br>'), findsNothing);
      expect(find.textContaining('line1'), findsOneWidget);
      expect(find.text('author'), findsWidgets);

      await tester.tap(find.text('author').last);
      await tester.pumpAndSettle();
      expect(
        find.byType(Scaffold).evaluate().length,
        greaterThanOrEqualTo(2),
        reason: 'in-app pixiv link pushes a detail page route',
      );
    });
  });
}
