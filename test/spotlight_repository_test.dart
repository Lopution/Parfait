import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/spotlight/spotlight_models.dart';
import 'package:pixiv_func/core/spotlight/spotlight_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/spotlight_world.dart';
import 'helpers/test_preferences.dart';

Future<PixivSpotlightRepository> _repo(SpotlightFixture fixture) async {
  final (container, _) = await makeSpotlightWorld(fixture: fixture);
  addTearDown(container.dispose);
  return PixivSpotlightRepository(container.read(pixivHttpClientProvider));
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('requests /v1/spotlight/articles with category and filter', () async {
    final fixture = SpotlightFixture();
    final repo = await _repo(fixture);
    final page = await repo.fetchArticles(category: SpotlightCategory.illust);

    expect(fixture.requests.single.path, '/v1/spotlight/articles');
    expect(fixture.requests.single.queryParameters['category'], 'illust');
    expect(fixture.requests.single.queryParameters['filter'], 'for_android');
    expect(page.articles.map((a) => a.id), [101, 102]);
    expect(page.articles.first.pureTitle, 'pure 101');
    expect(page.articles.first.articleUrl, 'https://www.pixivision.net/a/101');
    expect(page.articles.first.subcategoryLabel, 'label 101');
    expect(page.nextUrl, contains('offset=10'));
  });

  test('passes the validated offset cursor through', () async {
    final fixture = SpotlightFixture();
    final repo = await _repo(fixture);
    final page = await repo.fetchArticles(
      category: SpotlightCategory.all,
      cursor:
          'https://app-api.pixiv.net/v1/spotlight/articles'
          '?filter=for_android&category=all&offset=10',
    );
    expect(fixture.requests.single.queryParameters['offset'], '10');
    expect(page.articles.map((a) => a.id), [103]);
  });

  test('malformed envelope raises ApiParseError', () async {
    final repo = await _repo(_MalformedFixture());
    expect(() => repo.fetchArticles(), throwsA(isA<ApiParseError>()));
  });

  test('validateArticlesCursor pins path and category', () async {
    final repo = await _repo(SpotlightFixture());
    expect(
      repo.validateArticlesCursor(
        SpotlightCategory.illust,
        cursor:
            'https://app-api.pixiv.net/v1/spotlight/articles'
            '?filter=for_android&category=illust&offset=10',
      ),
      isTrue,
    );
    expect(
      repo.validateArticlesCursor(
        SpotlightCategory.illust,
        cursor:
            'https://app-api.pixiv.net/v1/spotlight/articles'
            '?filter=for_android&category=manga&offset=10',
      ),
      isFalse,
      reason: 'a cursor for another category must be rejected',
    );
    expect(
      repo.validateArticlesCursor(
        SpotlightCategory.illust,
        cursor:
            'https://app-api.pixiv.net/v1/search/illust'
            '?word=x&category=illust&filter=for_android',
      ),
      isFalse,
    );
  });
}

class _MalformedFixture extends SpotlightFixture {
  @override
  http.Client client() => MockClient(
    (request) async => http.Response(
      jsonEncode(<String, dynamic>{'bogus': true}),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );
}
