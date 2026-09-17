import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/http_client_providers.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
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
          spotlightArticleJson(101, category: category),
          spotlightArticleJson(102, category: category),
        ],
        'next_url':
            'https://app-api.pixiv.net/v1/spotlight/articles'
            '?filter=for_android&category=${mismatchedNextCategory ?? category}'
            '&offset=10',
      });
    }
    return _ok({
      'spotlight_articles': [spotlightArticleJson(103, category: category)],
      'next_url': null,
    });
  });

  http.Response _ok(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// [webClient] overrides the shared third-party client (pixivision article
/// HTML fetches); pass a MockClient to assert request headers.
Future<(ProviderContainer, SpotlightFixture)> makeSpotlightWorld({
  SpotlightFixture? fixture,
  http.Client? webClient,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? SpotlightFixture();
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in the spotlight fixture');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      if (webClient != null)
        thirdPartyHttpClientProvider.overrideWithValue(webClient),
    ],
  );
  final client = PixivHttpClient(
    client: activeFixture.client(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return (container, activeFixture);
}
