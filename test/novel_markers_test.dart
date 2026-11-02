import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/novel/novel_feed_controller.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/features/novel/novel_markers_page.dart';
import 'package:parfait/features/novel/novel_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';

const _markers = '/v2/novel/markers';

Map<String, dynamic> _marked(int id, int page) => {
  'novel': novelJson(id, title: 'marked $id'),
  'novel_marker': {'page': page},
};

/// The bookmark list's App API over [routes], with the reads every page
/// makes in the background.
PixivApi _api(Map<String, ApiRoute> routes) =>
    PixivApi({...backgroundRoutes, ...routes});

Future<ProviderContainer> _world(PixivApi api) => signedInApiContainer(
  api.client,
  overrides: [
    feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
  ],
);

void main() {
  test('the bookmark list pages by next_url; each novel lands with its '
      'bookmark', () async {
    final api = _api({
      _markers: (request) => jsonResponse(
        request.url.queryParameters.containsKey('offset')
            ? {
                'marked_novels': [_marked(3, 1)],
                'next_url': null,
              }
            : {
                'marked_novels': [_marked(1, 2), _marked(2, 5)],
                'next_url': nextUrl(request, 30),
              },
      ),
    });
    final container = await _world(api);
    final feed = markedNovelsFeedProvider;
    container.listen(feed, (_, _) {});

    await container.read(feed.future);
    await container.read(feed.notifier).loadMore();

    expect(container.read(feed).requireValue.ids, [1, 2, 3]);
    expect(api.sent(_markers).map((request) => request.url.queryParameters), [
      <String, String>{},
      {'offset': '30'},
    ]);
    final novels = container.read(novelStoreProvider);
    expect(
      [
        for (final id in [1, 2, 3]) novels[id]!.markerPage,
      ],
      [2, 5, 1],
    );
    expect(container.read(markedNovelPagesProvider), {1: 2, 2: 5, 3: 1});
  });

  test('an entry without a novel or a page is a parse error', () async {
    for (final entry in <Object>[
      {
        'novel_marker': const {'page': 2},
      },
      {'novel': novelJson(1), 'novel_marker': const <String, Object>{}},
      {
        'novel': novelJson(1),
        'novel_marker': const {'page': 0},
      },
    ]) {
      final container = await _world(
        _api({
          _markers: answer({
            'marked_novels': [entry],
            'next_url': null,
          }),
        }),
      );
      final feed = markedNovelsFeedProvider;
      container.listen(feed, (_, _) {});
      final state = await container.read(feed.future);
      expect(state.initialError, isA<ApiParseError>(), reason: '$entry');
      container.dispose();
    }
  });

  testWidgets('rows say where the bookmark is and open there; the button '
      'removes it and puts it back', (tester) async {
    var failWrites = false;
    final writes = <http.Request>[];
    http.Response write(http.Request request) {
      writes.add(request);
      return failWrites
          ? jsonResponse({
              'error': {'message': 'nope'},
            }, 400)
          : jsonResponse(const <String, Object>{});
    }

    final container = await _world(
      _api({
        _markers: answer({
          'marked_novels': [_marked(1, 2)],
          'next_url': null,
        }),
        '/v2/novel/detail': answer({'novel': novelJson(1, title: 'marked 1')}),
        // The reader opens; its text is not this test's.
        '/webview/v2/novel': failing(503),
        '/v1/novel/marker/add': write,
        '/v1/novel/marker/delete': write,
      }),
    );
    final router = pixivRouter('/settings/novel-markers');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        container: container,
        builder: promptHostBuilder,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('marked 1'), findsOneWidget);
    expect(find.text('书签 · 第 2 页'), findsOneWidget);

    await tester.tap(find.byTooltip('删除书签'));
    await tester.pumpAndSettle();
    expect(requestFields(writes.single), {'novel_id': '1'});
    expect(writes.single.url.path, '/v1/novel/marker/delete');
    // The row stays, its page kept for putting it back.
    expect(find.text('书签 · 第 2 页'), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);

    failWrites = true;
    await tester.tap(find.byTooltip('加回书签'));
    await tester.pumpAndSettle();
    expect(find.textContaining('书签操作失败'), findsOneWidget);
    expect(find.byTooltip('加回书签'), findsOneWidget);
    PromptHost.of(tester.element(find.byType(NovelMarkersPage))).hideCurrent();
    await tester.pumpAndSettle();

    failWrites = false;
    await tester.tap(find.byTooltip('加回书签'));
    await tester.pumpAndSettle();
    expect(writes.last.url.path, '/v1/novel/marker/add');
    expect(requestFields(writes.last), {'novel_id': '1', 'page': '2'});
    expect(find.byTooltip('删除书签'), findsOneWidget);
    expect(container.read(novelStoreProvider)[1]!.markerPage, 2);

    // The row opens the novel at its bookmark.
    await tester.tap(find.text('marked 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/settings/novel/1');
    expect(tester.widget<NovelPage>(find.byType(NovelPage)).atPixivPage, 2);
  });

  testWidgets('an empty list and a failed one say so', (tester) async {
    for (final (route, text) in [
      (answer(pageJson('marked_novels', const [])), '暂无小说书签'),
      (failing(503), '小说书签加载失败'),
    ]) {
      final container = await _world(_api({_markers: route}));
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: const NovelMarkersPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
