import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/features/novel/novel_page.dart';
import 'package:parfait/features/novel/novel_series_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';

const _series = '/v2/novel/series';

/// Part [id] of series 5, its [id]th novel.
Map<String, dynamic> _part(int id) => {
  ...novelJson(id, title: 'part $id'),
  'content_order': '$id',
  'series': {'id': 5, 'title': 'saga'},
};

String _webview(int id) =>
    '''
<script>
Object.defineProperty(window, 'pixiv', {value: {
  "context": {"csrfToken": "x"},
  "novel": ${jsonEncode({'id': '$id', 'title': 'part $id', 'text': 'text of part $id', 'userId': '99', 'coverUrl': 'https://i.pximg.net/c/$id.jpg', 'tags': <String>[], 'caption': ''})},
}, configurable: true, writable: true});
</script>
''';

void main() {
  testWidgets('a series page: its facts, numbered novels past the first '
      'page, a restricted one, and reading on from where you left', (
    tester,
  ) async {
    var malformed = true;
    final api = PixivApi({
      ...backgroundRoutes,
      ...shellRoutes,
      _series: (request) {
        if (malformed) {
          return jsonResponse({
            'novels': [
              {'id': 1},
            ],
            'next_url': null,
          });
        }
        if (request.url.queryParameters['last_order'] == '2') {
          return jsonResponse({
            'novels': [_part(3)],
            'next_url': null,
          });
        }
        return jsonResponse({
          'novel_series_detail': {
            'id': 5,
            'title': 'saga',
            'caption': 'a long tale',
            'is_original': true,
            'is_concluded': true,
            'content_count': 3,
            'user': novelJson(1)['user'],
            'watchlist_added': false,
          },
          'novel_series_first_novel': novelJson(1),
          'novel_series_latest_novel': novelJson(3),
          'novels': [
            _part(1),
            // A restricted entry carries no author.
            {
              'id': 2,
              'title': 'part 2',
              'visible': false,
              'viewable_message': 'hidden by its author',
              'content_order': '2',
              'user': {'id': 0, 'name': ''},
            },
          ],
          'next_url': request.url
              .replace(
                queryParameters: {
                  ...request.url.queryParameters,
                  'last_order': '2',
                },
              )
              .toString(),
        });
      },
      '/v2/novel/detail': (request) => jsonResponse({
        'novel': _part(int.parse(request.url.queryParameters['novel_id']!)),
      }),
      '/webview/v2/novel': (request) => http.Response.bytes(
        utf8.encode(_webview(int.parse(request.url.queryParameters['id']!))),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    });
    final container = await signedInApiContainer(
      api.client,
      others: const [Account(id: '200', userId: 200, name: 'b')],
    );
    // The store still holds the restricted novel from when it was not.
    container.read(novelStoreProvider.notifier).mergeAll([
      NovelEntity.fromJson(_part(2)),
    ]);
    final router = pixivRouter('/settings/novel-series/5');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        container: container,
        builder: promptHostBuilder,
      ),
    );
    await tester.pumpAndSettle();

    // A malformed entry fails the page, which retries.
    expect(find.text('系列加载失败'), findsOneWidget);
    malformed = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('a long tale'), findsOneWidget);
    expect(find.text('共 3 个作品 · 已完结 · 原创'), findsOneWidget);
    expect(find.text('author'), findsWidgets);
    expect(find.text('第 1 话'), findsOneWidget);
    expect(find.text('hidden by its author'), findsOneWidget);
    expect(find.text('第 3 话'), findsOneWidget);
    expect(api.sent(_series, {'last_order': '2'}), hasLength(1));
    // Rows leave out the series the page is.
    expect(find.text('1200 字'), findsWidgets);
    expect(find.textContaining('saga ·'), findsNothing);
    // The latest's number is known once its entry has loaded; its label
    // lines up with the text above.
    expect(find.text('阅读最新第 3 话'), findsOneWidget);
    expect(
      tester.getRect(find.text('阅读最新第 3 话')).left,
      tester.getRect(find.text('a long tale')).left,
    );
    expect(find.textContaining('继续'), findsNothing);

    // A restricted novel does not open.
    await tester.tap(find.text('hidden by its author'));
    await tester.pumpAndSettle();
    expect(find.byType(NovelPage), findsNothing);

    // Reading from the first remembers the series' place for this
    // account only.
    await tester.tap(find.text('开始阅读'));
    await tester.pumpAndSettle();
    expect(tester.widget<NovelPage>(find.byType(NovelPage)).novelId, 1);
    final records = container.read(novelSeriesLastReadStoreProvider);
    expect(await records.read(testerAccount.id, 5), 1);
    expect(await records.read('200', 5), isNull);

    // The info sheet's series and the reader's series bar both lead back,
    // to a page that continues there.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('novel-info-series')));
    await tester.pumpAndSettle();
    expect(find.byType(NovelSeriesFeedPage), findsOneWidget);
    expect(find.text('继续第 1 话'), findsOneWidget);
    expect(find.text('从第 1 话开始'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(NovelSeriesFeedPage), findsNothing);
    await tester.tap(find.byKey(const Key('novel-series-bar-title')));
    await tester.pumpAndSettle();
    expect(find.text('继续第 1 话'), findsOneWidget);
  });
}
