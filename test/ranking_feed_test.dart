import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/features/ranking/ranking_repository.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FakeCredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _FakeMetadataRepository implements AccountMetadataRepository {
  _FakeMetadataRepository({this.twoAccounts = false});

  final bool twoAccounts;

  @override
  Future<AccountMetadataSnapshot> load() async => AccountMetadataSnapshot(
    accounts: [
      const Account(id: '100', userId: 100, name: 'tester'),
      if (twoAccounts) const Account(id: '200', userId: 200, name: 'second'),
    ],
    currentId: '100',
  );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

Map<String, dynamic> _illust(int id) => {
  'id': id,
  'title': 'ranking $id',
  'type': 'illust',
  'image_urls': {
    'square_medium': 'https://i.pximg.net/$id/s.png',
    'medium': 'https://i.pximg.net/$id/m.png',
    'large': 'https://i.pximg.net/$id/l.png',
  },
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'tags': <Object>[],
  'page_count': 1,
  'width': 100,
  'height': 140,
  'x_restrict': 0,
  'illust_ai_type': 0,
  'is_bookmarked': false,
  'visible': true,
};

class _RankingFixture {
  final requests = <Uri>[];
  final Completer<void> release = Completer<void>();
  RankingMode? mismatchedNextMode;
  bool blockResponses = false;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    if (blockResponses) await release.future;
    final mode = request.url.queryParameters['mode']!;
    final isFirst = request.url.queryParameters['offset'] == null;
    final accountOffset = request.headers['authorization'] == 'Bearer access-2'
        ? 100
        : 0;
    final start = accountOffset + (isFirst ? 1 : 3);
    final nextMode = mismatchedNextMode?.apiValue ?? mode;
    return http.Response(
      jsonEncode({
        'illusts': [for (var id = start; id < start + 2; id++) _illust(id)],
        'next_url': isFirst
            ? 'https://app-api.pixiv.net/v1/illust/ranking'
                  '?filter=for_android&mode=$nextMode&offset=30'
            : null,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<(ProviderContainer, _RankingFixture)> _makeWorld({
  _RankingFixture? fixture,
  bool twoAccounts = false,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final activeFixture = fixture ?? _RankingFixture();
  final credentials = _FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    )
    ..seed(
      '200',
      const Credential(accessToken: 'access-2', refreshToken: 'refresh-2'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        _FakeMetadataRepository(twoAccounts: twoAccounts),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in ranking fixture');
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
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('RankingMode has explicit beta56 order and API values', () {
    expect(RankingMode.values.map((mode) => mode.apiValue), [
      'day',
      'day_r18',
      'day_male',
      'day_male_r18',
      'day_female',
      'day_female_r18',
      'week',
      'week_r18',
      'week_original',
      'week_rookie',
      'month',
    ]);
    expect(RankingMode.fromApiValue('week_rookie'), RankingMode.weekRookie);
    expect(RankingMode.fromApiValue('unknown'), isNull);
  });

  test('each mode has independent first page and load-more state', () async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    final day = await container.read(
      rankingFeedControllerProvider(RankingMode.day).future,
    );
    final week = await container.read(
      rankingFeedControllerProvider(RankingMode.week).future,
    );
    expect(day.ids, [1, 2]);
    expect(week.ids, [1, 2]);
    expect(fixture.requests.map((uri) => uri.queryParameters['mode']), [
      'day',
      'week',
    ]);

    await container
        .read(rankingFeedControllerProvider(RankingMode.day).notifier)
        .loadMore();
    final dayAfter = container
        .read(rankingFeedControllerProvider(RankingMode.day))
        .requireValue;
    final weekAfter = container
        .read(rankingFeedControllerProvider(RankingMode.week))
        .requireValue;
    expect(dayAfter.ids, [1, 2, 3, 4]);
    expect(weekAfter.ids, [1, 2]);
    expect(weekAfter.exhausted, isFalse);
  });

  test('mismatched next mode is an observable parse error', () async {
    final (container, _) = await _makeWorld(
      fixture: (_RankingFixture()..mismatchedNextMode = RankingMode.week),
    );
    addTearDown(container.dispose);

    final state = await container.read(
      rankingFeedControllerProvider(RankingMode.day).future,
    );
    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(rankingFeedControllerProvider(RankingMode.day).notifier)
          .nextCursor,
      isNull,
    );
  });

  test(
    'account switching resets the mode controller and entity store',
    () async {
      final (container, fixture) = await _makeWorld(twoAccounts: true);
      addTearDown(container.dispose);

      final provider = rankingFeedControllerProvider(RankingMode.day);
      final firstStore = container.read(illustStoreProvider);
      expect((await container.read(provider.future)).ids, [1, 2]);

      await container.read(accountStoreProvider.notifier).switchAccount('200');
      final second = await container.read(provider.future);
      final secondStore = container.read(illustStoreProvider);

      expect(second.ids, [101, 102]);
      expect(secondStore, isNot(same(firstStore)));
      expect(fixture.requests, hasLength(2));
      expect(fixture.requests.last, isNotNull);
    },
  );

  test('cancel returns an active feed to idle without an error', () async {
    final fixture = _RankingFixture()..blockResponses = true;
    final (container, _) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    final future = container.read(
      rankingFeedControllerProvider(RankingMode.day).future,
    );
    await Future<void>.delayed(Duration.zero);
    container
        .read(rankingFeedControllerProvider(RankingMode.day).notifier)
        .cancel();
    final state = await future;
    expect(state.initialPhase.name, 'idle');
    expect(state.initialError, isNull);
  });

  testWidgets('renders all tabs and lazily requests the selected mode', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const RankingPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('每日'), findsOneWidget);
      expect(find.text('每月'), findsOneWidget);
      expect(fixture.requests, hasLength(1));

      await tester.tap(find.text('每日(R-18)'));
      await tester.pump();
      await tester.pump();
    });
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests.last.queryParameters['mode'], 'day_r18');
  });
}
