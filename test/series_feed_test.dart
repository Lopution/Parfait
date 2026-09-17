import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/paging/paged_feed_controller.dart';
import 'package:pixiv_func/core/series/illust_series_context_controller.dart';
import 'package:pixiv_func/core/series/series_feed_controller.dart';
import 'package:pixiv_func/core/series/series_store.dart';
import 'package:pixiv_func/features/series/illust_series_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

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

class _SeriesFixture {
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
            'illust_series_detail': _seriesDetailJson(seriesId),
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
          'illust_series_detail': _seriesDetailJson(seriesId),
          'illusts': [illustJson(910)],
          'next_url': null,
        });
      case '/v1/user/illust-series':
        final userId = int.parse(request.url.queryParameters['user_id']!);
        final offset = request.url.queryParameters['offset'];
        if (offset == null) {
          return _ok({
            'illust_series_details': [
              _seriesDetailJson(55, workCount: 12),
              _seriesDetailJson(56, workCount: 3, title: 'another'),
            ],
            'next_url':
                'https://app-api.pixiv.net/v1/user/illust-series'
                '?filter=for_android&user_id=$userId&offset=2',
          });
        }
        return _ok({
          'illust_series_details': [_seriesDetailJson(57, workCount: 5)],
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
          'illust_series_detail': _seriesDetailJson(55),
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

Future<(ProviderContainer, _SeriesFixture)> _makeWorld({
  _SeriesFixture? fixture,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? _SeriesFixture();
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

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test(
    'illust series feed loads page one and commits entities plus detail',
    () async {
      final (container, fixture) = await _makeWorld();
      addTearDown(container.dispose);

      final state = await container.read(illustSeriesFeedProvider(55).future);

      expect(state.ids, [912, 911]);
      expect(state.initialPhase, FeedPhase.idle);
      expect(state.exhausted, isFalse);
      expect(fixture.requests.single.path, '/v1/illust/series');
      expect(fixture.requests.single.queryParameters['illust_series_id'], '55');
      expect(fixture.requests.single.queryParameters['filter'], 'for_android');

      final illustStore = container.read(illustStoreProvider);
      expect(illustStore.get(912)?.title, 'illust 912');
      final seriesStore = container.read(illustSeriesStoreProvider);
      expect(seriesStore[55]?.workCount, 12);
      expect(seriesStore[55]?.latestContentId, 912);
    },
  );

  test('illust series feed paginates with the last_order cursor', () async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await container.read(illustSeriesFeedProvider(55).future);
    await container.read(illustSeriesFeedProvider(55).notifier).loadMore();
    final after = container.read(illustSeriesFeedProvider(55)).requireValue;

    expect(after.ids, [912, 911, 910]);
    expect(after.exhausted, isTrue);
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests.last.queryParameters['last_order'], '10');
    expect(fixture.requests.last.queryParameters['illust_series_id'], '55');
  });

  test(
    'a next_url for another series id is rejected before page two',
    () async {
      final (container, fixture) = await _makeWorld(
        fixture: _SeriesFixture()..mismatchedSeriesId = 56,
      );
      addTearDown(container.dispose);

      final state = await container.read(illustSeriesFeedProvider(55).future);

      expect(state.showInitialError, isTrue);
      expect(state.initialError, isNotNull);
      expect(
        container.read(illustSeriesFeedProvider(55).notifier).nextCursor,
        isNull,
      );
      expect(fixture.requests, hasLength(1));
    },
  );

  test('user series feed stores series ids and merges the store', () async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    final state = await container.read(userSeriesFeedProvider(7).future);
    expect(state.ids, [55, 56]);
    expect(fixture.requests.single.path, '/v1/user/illust-series');
    expect(fixture.requests.single.queryParameters['user_id'], '7');

    await container.read(userSeriesFeedProvider(7).notifier).loadMore();
    final after = container.read(userSeriesFeedProvider(7)).requireValue;
    expect(after.ids, [55, 56, 57]);
    expect(after.exhausted, isTrue);
    expect(fixture.requests.last.queryParameters['offset'], '2');

    final store = container.read(illustSeriesStoreProvider);
    expect(store[55]?.title, 'series 55');
    expect(store[56]?.workCount, 3);
    expect(store[57]?.workCount, 5);
  });

  test('illust series context merges detail and neighbour illusts', () async {
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);

    final context = await container.read(
      illustSeriesContextProvider(910).future,
    );

    expect(context?.seriesId, 55);
    expect(context?.contentOrder, 3);
    expect(context?.prevIllustId, 909);
    expect(context?.nextIllustId, 911);
    expect(container.read(illustSeriesStoreProvider)[55]?.id, 55);
    final illustStore = container.read(illustStoreProvider);
    expect(illustStore.get(909)?.title, 'illust 909');
    expect(illustStore.get(911)?.title, 'illust 911');
  });

  test('non-series work resolves to a null context', () async {
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);

    final context = await container.read(
      illustSeriesContextProvider(42).future,
    );

    expect(context, isNull);
    expect(container.read(illustSeriesStoreProvider), isEmpty);
  });

  testWidgets('series page renders header and works grid', (tester) async {
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const IllustSeriesPage(seriesId: 55),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // AppBar + header come from the committed series detail.
      expect(find.text('series 55'), findsWidgets);
      expect(find.text('共 12 个作品'), findsOneWidget);
      expect(find.text('author'), findsWidgets);
      expect(find.byType(IllustCard), findsNWidgets(2));
    });
  });
}
