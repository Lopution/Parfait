import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/illust/illust_detail_controller.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'download_world.dart';
import 'fake_account.dart';
import 'illust_fixtures.dart';
import 'memory_feed_snapshot_store.dart';
import 'test_preferences.dart';

/// Widget test host: real DownloadManager over a scripted transport +
/// memory sinks, detail API over a MockClient — no platform channels.
Future<(ProviderContainer, FakeTransport, MemorySinkFactory)> makeWorld({
  int scriptedResponses = 4,
  Map<int, Map<String, dynamic>>? detailOverrides,
  Map<int, List<Map<String, dynamic>>>? relatedOverrides,
  Set<String> mutedTags = const {},
  List<Override> extraOverrides = const [],
  Completer<void>? detailGate,
  List<int>? relatedLog,
  Completer<void>? relatedGate,
  Duration? progressThrottle,
  Map<int, List<Map<String, dynamic>>>? commentOverrides,
  Map<int, List<Map<String, dynamic>>>? authorWorksOverrides,
  List<String>? requestLog,
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
  final manager = progressThrottle == null
      ? DownloadManager(transport: transport, sinkFactory: sinks)
      : DownloadManager(
          transport: transport,
          sinkFactory: sinks,
          progressThrottle: progressThrottle,
        );
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
      // A fresh in-memory snapshot store per world: the default sqflite
      // store shares feeds.db across the whole file, so a related list
      // committed by one test would be restored (and refreshed) in the
      // next.
      feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
      ...extraOverrides,
    ],
  );
  final client = PixivHttpClient(
    client: MockClient((request) async {
      requestLog?.add(request.url.path);
      if (request.url.path == '/v1/illust/detail') {
        await detailGate?.future;
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
        relatedLog?.add(id);
        await relatedGate?.future;
        return okJson({
          'illusts': relatedOverrides?[id] ?? [],
          'next_url': null,
        });
      }
      // The detail page's comment preview and author strip.
      if (request.url.path == '/v3/illust/comments') {
        final id = int.parse(request.url.queryParameters['illust_id']!);
        return okJson({
          'comments': commentOverrides?[id] ?? [],
          'next_url': null,
        });
      }
      if (request.url.path == '/v1/user/illusts') {
        final id = int.parse(request.url.queryParameters['user_id']!);
        return okJson({
          'illusts': authorWorksOverrides?[id] ?? [],
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
