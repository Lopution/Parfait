import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/app/widgets/novel_entry.dart';
import 'package:pixiv_func/core/novel/novel_ranking_feed_controller.dart';
import 'package:pixiv_func/core/novel/novel_repository.dart';
import 'package:pixiv_func/core/novel/novel_store.dart';
import 'package:pixiv_func/features/ranking/novel_ranking_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

Map<String, dynamic> _novel(int id) => {
  'id': id,
  'title': 'novel ranking $id',
  'caption': '',
  'restrict': 0,
  'x_restrict': 0,
  'image_urls': {'medium': 'https://i.pximg.net/$id/m.png'},
  'tags': <Object>[],
  'text_length': 1200,
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'is_bookmarked': false,
  'visible': true,
};

class _RankingFixture {
  final requests = <Uri>[];
  NovelRankingMode? mismatchedNextMode;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final mode = request.url.queryParameters['mode']!;
    final isFirst = request.url.queryParameters['offset'] == null;
    final start = isFirst ? 1 : 3;
    final nextMode = mismatchedNextMode?.apiValue ?? mode;
    return http.Response(
      jsonEncode({
        'novels': [for (var id = start; id < start + 2; id++) _novel(id)],
        'next_url': isFirst
            ? 'https://app-api.pixiv.net/v1/novel/ranking'
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
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? _RankingFixture();
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
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('NovelRankingMode has explicit order and API values', () {
    expect(NovelRankingMode.values.map((mode) => mode.apiValue), [
      'day',
      'day_male',
      'day_female',
      'week',
      'week_ai',
      'week_ai_r18',
      'day_r18',
      'week_r18',
      'week_r18g',
    ]);
  });

  test('each mode has independent first page and load-more state', () async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    final day = await container.read(
      novelRankingFeedProvider(NovelRankingMode.day).future,
    );
    final week = await container.read(
      novelRankingFeedProvider(NovelRankingMode.week).future,
    );
    expect(day.ids, [1, 2]);
    expect(week.ids, [1, 2]);
    expect(fixture.requests.map((uri) => uri.path), [
      '/v1/novel/ranking',
      '/v1/novel/ranking',
    ]);
    expect(fixture.requests.map((uri) => uri.queryParameters['mode']), [
      'day',
      'week',
    ]);

    await container
        .read(novelRankingFeedProvider(NovelRankingMode.day).notifier)
        .loadMore();
    final dayAfter = container
        .read(novelRankingFeedProvider(NovelRankingMode.day))
        .requireValue;
    final weekAfter = container
        .read(novelRankingFeedProvider(NovelRankingMode.week))
        .requireValue;
    expect(dayAfter.ids, [1, 2, 3, 4]);
    expect(weekAfter.ids, [1, 2]);
    expect(weekAfter.exhausted, isFalse);
  });

  test('entities land in the novel store under ranking ids', () async {
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);

    await container.read(novelRankingFeedProvider(NovelRankingMode.day).future);
    final store = container.read(novelStoreProvider);
    expect(store[1]?.title, 'novel ranking 1');
    expect(store[2]?.id, 2);
  });

  test('mismatched next mode is an observable parse error', () async {
    final (container, _) = await _makeWorld(
      fixture: (_RankingFixture()..mismatchedNextMode = NovelRankingMode.week),
    );
    addTearDown(container.dispose);

    final state = await container.read(
      novelRankingFeedProvider(NovelRankingMode.day).future,
    );
    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(novelRankingFeedProvider(NovelRankingMode.day).notifier)
          .nextCursor,
      isNull,
    );
  });

  testWidgets('renders tabs and lazily requests the selected mode', (
    tester,
  ) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const NovelRankingPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('每日'), findsOneWidget);
      expect(fixture.requests, hasLength(1));

      await tester.tap(find.text('每日(男性欢迎)'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
    });
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests.last.queryParameters['mode'], 'day_male');
  });

  testWidgets('rank badges land on the ranked novel entries', (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const NovelRankingPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The first day-mode page carries novels 1 and 2; each entry pins
      // its rank pill to the cover's top-left corner (O4).
      final entries = find.byType(NovelEntry);
      expect(entries, findsNWidgets(2));
      expect(
        find.descendant(of: entries.at(0), matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: entries.at(1), matching: find.text('2')),
        findsOneWidget,
      );
      expect(fixture.requests, isNotEmpty);
    });
  });
}
