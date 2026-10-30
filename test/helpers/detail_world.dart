import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/illust/illust_detail_controller.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';

import 'download_world.dart';
import 'fake_account.dart';
import 'illust_fixtures.dart';
import 'memory_feed_snapshot_store.dart';

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
  bool relatedEndless = false,
  Duration? progressThrottle,
  Map<int, List<Map<String, dynamic>>>? commentOverrides,
  Map<int, List<Map<String, dynamic>>>? authorWorksOverrides,
  List<String>? requestLog,
}) async {
  var relatedPages = 1;
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
  final container = await signedInApiContainer(
    MockClient((request) async {
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
        // Endless: a fresh offset every page, as pixiv's cursors carry.
        return okJson({
          'illusts': relatedOverrides?[id] ?? [],
          'next_url': relatedEndless
              ? 'https://app-api.pixiv.net/v2/illust/related?illust_id=$id'
                    '&offset=${relatedPages++}'
              : null,
        });
      }
      // The detail page's comment preview and author strip.
      if (request.url.path == '/v3/illust/comments') {
        final id = int.parse(request.url.queryParameters['illust_id']!);
        final comments = commentOverrides?[id] ?? [];
        return okJson({
          'comments': comments,
          'total_comments': comments.length,
          'next_url': null,
        });
      }
      // A comment sent from the detail page comes back as pixiv's would.
      if (request.url.path == '/v1/illust/comment/add') {
        final form = Uri.splitQueryString(request.body);
        return okJson({
          'comment': {
            'id': 900,
            'comment': form['comment'] ?? '',
            'date': '2026-10-21T10:00:00+09:00',
            'user': {
              'id': 1,
              'name': 'me',
              'account': 'me',
              'profile_image_urls': <String, String>{},
            },
            'has_replies': false,
          },
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
    overrides: [
      downloadManagerProvider.overrideWithValue(manager),
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
  return (container, transport, sinks);
}

http.Response okJson(Map<String, dynamic> json) => jsonResponse(json);
