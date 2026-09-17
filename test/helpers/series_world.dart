import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_account.dart';
import 'illust_fixtures.dart';
import 'test_preferences.dart';

Map<String, dynamic> seriesDetailJson(
  int id, {
  int workCount = 12,
  String title = 'series',
}) => {
  'id': id,
  'title': '$title $id',
  'caption': 'caption $id',
  'user': {'id': 7, 'name': 'author', 'account': 'author'},
  'cover_image_urls': {
    'link_360': 'https://i.pximg.net/s$id/360.jpg',
    'link_1200': 'https://i.pximg.net/s$id/1200.jpg',
  },
  'series_work_count': workCount,
  'watchlist_added': false,
  'is_concluded': false,
  'display_text': '',
};

/// Mock-HTTP world for the series endpoints (`/v1/illust/series`,
/// `/v1/user/illust-series`, `/v1/illust-series/illust`). The system under
/// test (repository, feed controllers, stores) runs real; only the network
/// boundary is faked.
class SeriesFixture {
  final requests = <Uri>[];

  /// When set, page-one next_urls carry this series id instead of the
  /// requested one — the feed must reject the cursor before page two.
  int? mismatchedSeriesId;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    switch (request.url.path) {
      case '/v1/illust/series':
        final seriesId = int.parse(
          request.url.queryParameters['illust_series_id']!,
        );
        final lastOrder = request.url.queryParameters['last_order'];
        if (lastOrder == null) {
          return _ok({
            'illust_series_detail': seriesDetailJson(seriesId),
            'illust_series_first_illust': illustJson(901),
            'illust_series_latest_illust': illustJson(912),
            'illusts': [illustJson(912), illustJson(911)],
            'next_url':
                'https://app-api.pixiv.net/v1/illust/series'
                '?filter=for_android&illust_series_id='
                '${mismatchedSeriesId ?? seriesId}&last_order=10',
          });
        }
        return _ok({
          'illust_series_detail': seriesDetailJson(seriesId),
          'illusts': [illustJson(910)],
          'next_url': null,
        });
      case '/v1/user/illust-series':
        final userId = int.parse(request.url.queryParameters['user_id']!);
        final offset = request.url.queryParameters['offset'];
        if (offset == null) {
          return _ok({
            'illust_series_details': [
              seriesDetailJson(55, workCount: 12),
              seriesDetailJson(56, workCount: 3, title: 'another'),
            ],
            'next_url':
                'https://app-api.pixiv.net/v1/user/illust-series'
                '?filter=for_android&user_id=$userId&offset=2',
          });
        }
        return _ok({
          'illust_series_details': [seriesDetailJson(57, workCount: 5)],
          'next_url': null,
        });
      case '/v1/illust-series/illust':
        final illustId = int.parse(request.url.queryParameters['illust_id']!);
        if (illustId == 42) {
          return _ok(<String, dynamic>{
            'illust_series_detail': null,
            'illust_series_context': null,
          });
        }
        return _ok({
          'illust_series_detail': seriesDetailJson(55),
          'illust_series_context': {
            'content_order': '3',
            'prev': illustJson(909),
            'next': illustJson(911),
          },
        });
    }
    fail('unexpected request: ${request.url}');
  });

  http.Response _ok(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Future<(ProviderContainer, SeriesFixture)> makeSeriesWorld({
  SeriesFixture? fixture,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? SeriesFixture();
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
            fail('refresh should not happen in the series fixture');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
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
