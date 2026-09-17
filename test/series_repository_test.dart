import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/series/series_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _seriesDetailJson(
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

Future<PixivSeriesRepository> _repo(MockClient client) async {
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final container = ProviderContainer(
    overrides: [
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      credentialStoreProvider.overrideWithValue(credentials),
    ],
  );
  addTearDown(container.dispose);
  final pixiv = PixivHttpClient(
    client: client,
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return PixivSeriesRepository(pixiv);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  group('PixivSeriesRepository.fetchSeriesWorks', () {
    test(
      'requests /v1/illust/series with illust_series_id and filter',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/v1/illust/series');
          expect(request.url.queryParameters['illust_series_id'], '55');
          expect(request.url.queryParameters['filter'], 'for_android');
          return _ok({
            'illust_series_detail': _seriesDetailJson(55),
            'illust_series_first_illust': illustJson(901),
            'illust_series_latest_illust': illustJson(912),
            'illusts': [illustJson(912), illustJson(911)],
            'next_url': null,
          });
        });
        final repo = await _repo(client);
        final page = await repo.fetchSeriesWorks(55);
        expect(page.detail?.id, 55);
        expect(page.detail?.title, 'series 55');
        expect(page.detail?.workCount, 12);
        expect(page.detail?.coverUrl, 'https://i.pximg.net/s55/360.jpg');
        expect(page.detail?.latestContentId, 912);
        expect(page.illusts.map((e) => e.id), [912, 911]);
        expect(page.nextUrl, isNull);
      },
    );

    test('passes the validated last_order cursor through', () async {
      const cursor =
          'https://app-api.pixiv.net/v1/illust/series'
          '?filter=for_android&illust_series_id=55&last_order=10';
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/illust/series');
        expect(request.url.queryParameters['last_order'], '10');
        expect(request.url.queryParameters['illust_series_id'], '55');
        return _ok({
          'illust_series_detail': _seriesDetailJson(55),
          'illusts': [illustJson(910)],
          'next_url': null,
        });
      });
      final repo = await _repo(client);
      final page = await repo.fetchSeriesWorks(55, cursor: cursor);
      expect(page.illusts.map((e) => e.id), [910]);
    });

    test('malformed envelope raises ApiParseError', () async {
      final client = MockClient((request) async => _ok({'bogus': true}));
      final repo = await _repo(client);
      expect(() => repo.fetchSeriesWorks(55), throwsA(isA<ApiParseError>()));
    });

    test(
      'a cursor for another series is rejected before the request',
      () async {
        var requested = false;
        final client = MockClient((request) async {
          requested = true;
          return _ok({'illusts': <Object?>[], 'next_url': null});
        });
        final repo = await _repo(client);
        expect(
          () => repo.fetchSeriesWorks(
            55,
            cursor:
                'https://app-api.pixiv.net/v1/illust/series'
                '?filter=for_android&illust_series_id=56&last_order=10',
          ),
          throwsA(isA<ApiParseError>()),
        );
        expect(requested, isFalse);
      },
    );
  });

  group('PixivSeriesRepository.fetchIllustSeriesContext', () {
    test('parses detail, content order and prev/next works', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/illust-series/illust');
        expect(request.url.queryParameters['illust_id'], '910');
        return _ok({
          'illust_series_detail': _seriesDetailJson(55),
          'illust_series_context': {
            'content_order': '3',
            'prev': illustJson(909),
            'next': illustJson(911),
          },
        });
      });
      final repo = await _repo(client);
      final result = await repo.fetchIllustSeriesContext(910);
      expect(result.detail?.id, 55);
      expect(result.context?.seriesId, 55);
      expect(result.context?.contentOrder, 3);
      expect(result.context?.prevIllustId, 909);
      expect(result.context?.nextIllustId, 911);
      expect(result.prevIllust?.title, 'illust 909');
    });

    test('non-series work returns null context and detail', () async {
      final client = MockClient(
        (request) async => _ok(<String, dynamic>{
          'illust_series_detail': null,
          'illust_series_context': null,
        }),
      );
      final repo = await _repo(client);
      final result = await repo.fetchIllustSeriesContext(42);
      expect(result.detail, isNull);
      expect(result.context, isNull);
      expect(result.prevIllust, isNull);
      expect(result.nextIllust, isNull);
    });
  });

  group('PixivSeriesRepository.fetchUserSeries', () {
    test(
      'requests /v1/user/illust-series and parses the details list',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/v1/user/illust-series');
          expect(request.url.queryParameters['user_id'], '7');
          expect(request.url.queryParameters['filter'], 'for_android');
          return _ok({
            'illust_series_details': [
              _seriesDetailJson(55, workCount: 12),
              _seriesDetailJson(56, workCount: 3, title: 'another'),
            ],
            'next_url':
                'https://app-api.pixiv.net/v1/user/illust-series'
                '?filter=for_android&user_id=7&offset=30',
          });
        });
        final repo = await _repo(client);
        final page = await repo.fetchUserSeries(7);
        expect(page.series.map((e) => e.id), [55, 56]);
        expect(page.series[1].workCount, 3);
        expect(page.nextUrl, contains('offset=30'));
      },
    );

    test('malformed envelope raises ApiParseError', () async {
      final client = MockClient((request) async => _ok({'bogus': true}));
      final repo = await _repo(client);
      expect(() => repo.fetchUserSeries(7), throwsA(isA<ApiParseError>()));
    });
  });

  group('cursor validation', () {
    test('validateSeriesCursor pins path and series id', () async {
      final client = MockClient(
        (request) async => _ok({'illusts': <Object?>[], 'next_url': null}),
      );
      final repo = await _repo(client);
      expect(
        repo.validateSeriesCursor(
          55,
          cursor:
              'https://app-api.pixiv.net/v1/illust/series'
              '?filter=for_android&illust_series_id=55&last_order=9',
        ),
        isTrue,
      );
      expect(
        repo.validateSeriesCursor(
          55,
          cursor:
              'https://app-api.pixiv.net/v1/illust/series'
              '?filter=for_android&illust_series_id=56&last_order=9',
        ),
        isFalse,
        reason: 'a cursor pointing at another series must be rejected',
      );
      expect(
        repo.validateSeriesCursor(
          55,
          cursor:
              'https://app-api.pixiv.net/v1/search/illust'
              '?word=x&illust_series_id=55&filter=for_android',
        ),
        isFalse,
      );
      expect(
        repo.validateSeriesCursor(55, cursor: 'https://evil.example.com/x'),
        isFalse,
      );
    });

    test('validateUserSeriesCursor pins path and user id', () async {
      final client = MockClient(
        (request) async => _ok({'illusts': <Object?>[], 'next_url': null}),
      );
      final repo = await _repo(client);
      expect(
        repo.validateUserSeriesCursor(
          7,
          cursor:
              'https://app-api.pixiv.net/v1/user/illust-series'
              '?filter=for_android&user_id=7&offset=30',
        ),
        isTrue,
      );
      expect(
        repo.validateUserSeriesCursor(
          7,
          cursor:
              'https://app-api.pixiv.net/v1/user/illust-series'
              '?filter=for_android&user_id=8&offset=30',
        ),
        isFalse,
      );
    });
  });
}
