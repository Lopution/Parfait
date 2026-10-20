import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/network/http_client_providers.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_account.dart';
import 'test_preferences.dart';

Map<String, dynamic> spotlightArticleJson(
  int id, {
  String title = 'spotlight',
  String category = 'illust',
}) => {
  'id': id,
  'title': '$title $id',
  'pure_title': 'pure $id',
  'thumbnail': 'https://i.pximg.net/spotlight/$id.jpg',
  'article_url': 'https://www.pixivision.net/a/$id',
  'publish_date': '2026-09-01',
  'category': category,
  'subcategory_label': 'label $id',
};

/// Mock-HTTP world for `/v1/spotlight/articles`. The system under test
/// (repository, feed controller, store) runs real; only the network
/// boundary is faked.
class SpotlightFixture {
  final requests = <Uri>[];

  /// When set, page-one next_url carries this category instead of the
  /// requested one — the feed must reject the cursor before page two.
  String? mismatchedNextCategory;

  /// Articles on page one, ids from 101.
  int firstPageSize = 2;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    if (request.url.path != '/v1/spotlight/articles') {
      fail('unexpected request: ${request.url}');
    }
    final category = request.url.queryParameters['category']!;
    final offset = request.url.queryParameters['offset'];
    if (offset == null) {
      return _ok({
        'spotlight_articles': [
          for (var id = 101; id < 101 + firstPageSize; id++)
            spotlightArticleJson(id, category: category),
        ],
        'next_url':
            'https://app-api.pixiv.net/v1/spotlight/articles'
            '?filter=for_android&category=${mismatchedNextCategory ?? category}'
            '&offset=10',
      });
    }
    return _ok({
      'spotlight_articles': [
        spotlightArticleJson(101 + firstPageSize, category: category),
      ],
      'next_url': null,
    });
  });

  http.Response _ok(Map<String, dynamic> body) => jsonResponse(body);
}

/// [webClient] overrides the shared third-party client (pixivision article
/// HTML fetches); pass a MockClient to assert request headers.
Future<(ProviderContainer, SpotlightFixture)> makeSpotlightWorld({
  SpotlightFixture? fixture,
  http.Client? webClient,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? SpotlightFixture();
  final container = await signedInApiContainer(
    activeFixture.client(),
    overrides: [
      if (webClient != null)
        thirdPartyHttpClientProvider.overrideWithValue(webClient),
    ],
  );
  return (container, activeFixture);
}
