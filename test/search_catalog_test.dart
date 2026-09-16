import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/pixiv_image.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/search/search_autocomplete_controller.dart';
import 'package:pixiv_func/core/search/search_feed_controller.dart';
import 'package:pixiv_func/core/search/search_models.dart';
import 'package:pixiv_func/core/search/search_repository.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_page.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/features/search/search_result_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

class _FakeSearchRepository implements SearchRepository {
  _FakeSearchRepository({this.autocompleteHandler, this.trendingTagCount = 2});

  final Future<List<SearchSuggestion>> Function(
    String keyword,
    CancelToken? cancelToken,
  )?
  autocompleteHandler;
  final requests = <SearchQuery>[];

  SearchIllustPage illustPage = const SearchIllustPage(
    illusts: [],
    nextUrl: null,
  );

  @override
  Future<SearchIllustPage> searchIllust(
    IllustSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    return illustPage;
  }

  @override
  Future<SearchNovelPage> searchNovel(
    NovelSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    return const SearchNovelPage(novels: [], nextUrl: null);
  }

  @override
  Future<SearchUserPage> searchUsers(
    UserSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    return const SearchUserPage(users: [], nextUrl: null);
  }

  @override
  bool validateCursor(SearchQuery query, {required String cursor}) => true;

  @override
  Future<List<SearchSuggestion>> autocomplete(
    String keyword, {
    CancelToken? cancelToken,
  }) {
    return autocompleteHandler?.call(keyword, cancelToken) ??
        Future.value(const []);
  }

  int trendingTagsCallCount = 0;
  SearchResultType? trendingTagsLastType;
  final int trendingTagCount;

  @override
  Future<List<TrendingTag>> trendingTags({
    SearchResultType type = SearchResultType.illust,
    CancelToken? cancelToken,
  }) async {
    trendingTagsCallCount++;
    trendingTagsLastType = type;
    final tags = <TrendingTag>[
      TrendingTag(name: '风景', representative: parseIllust(illustJson(901))),
      const TrendingTag(name: '猫'),
    ];
    for (var i = tags.length; i < trendingTagCount; i++) {
      tags.add(TrendingTag(name: '标签${i + 1}'));
    }
    return tags;
  }
}

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler, {
  bool accountIsPremium = false,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final credentials = FakeCredentialStore(
    values: const {
      'account': Credential(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
      ),
    },
  );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: [
            Account(
              id: 'account',
              userId: 8,
              name: 'tester',
              isPremium: accountIsPremium,
            ),
          ],
          currentId: 'account',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (_) async => throw StateError('refresh is not expected'),
          ),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client is not wired');
        return client;
      }),
    ],
  );
  final client = PixivHttpClient(
    client: MockClient(handler),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return container;
}

http.Response _json(Map<String, dynamic> value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('typed search filters serialize only allowlisted values', () {
    final filters = SearchFilters(
      target: SearchTarget.titleAndCaption,
      sort: SearchSort.popularDesc,
      startDate: DateTime(2026, 8, 1),
      endDate: DateTime(2026, 8, 27),
    );
    final query = IllustSearchQuery(keyword: '  cat  ', filters: filters);
    expect(query.toQuery(), {
      'word': 'cat',
      'search_target': 'title_and_caption',
      'sort': 'popular_desc',
      'start_date': '2026-08-01',
      'end_date': '2026-08-27',
      'filter': 'for_android',
    });
    expect(
      () => filters
          .copyWith(
            startDate: DateTime(2026, 8, 28),
            endDate: DateTime(2026, 8, 27),
          )
          .toQuery(word: 'cat'),
      throwsFormatException,
    );
  });

  test('partial-match tag target serializes explicitly', () {
    // search_target defaults to partial_match_for_tags server-side; every
    // comparable client sends it explicitly rather than relying on the
    // undocumented default.
    final query = const IllustSearchQuery(keyword: 'cat').toQuery();
    expect(query['search_target'], 'partial_match_for_tags');
    expect(query['sort'], 'date_desc');
  });

  test('duration presets resolve into absolute start/end dates', () {
    String fmt(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (final (duration, days) in [
      (SearchDuration.day, 1),
      (SearchDuration.week, 7),
      (SearchDuration.month, 30),
    ]) {
      final query = SearchFilters(duration: duration).toQuery(word: 'cat');
      // `within_last_*` is never sent — Pixiv's honoring of it on the app
      // API is unreliable, so every comparable client resolves presets
      // client-side.
      expect(query.containsKey('duration'), isFalse);
      expect(query['start_date'], fmt(today.subtract(Duration(days: days))));
      expect(query['end_date'], fmt(today));
    }
  });

  test('a duration preset wins over stale custom dates', () {
    final query = SearchFilters(
      duration: SearchDuration.day,
      startDate: DateTime(2020, 1, 1),
      endDate: DateTime(2020, 1, 2),
    ).toQuery(word: 'cat');
    // Mutually exclusive on the wire: the preset's resolved range replaces
    // the custom bounds instead of sending a contradictory mix.
    expect(query['start_date'], isNot('2020-01-01'));
    expect(query['end_date'], isNot('2020-01-02'));
    expect(query.containsKey('duration'), isFalse);
  });

  test('preview query drops the sort the preview endpoint rejects', () {
    final query = const SearchFilters(
      sort: SearchSort.popularDesc,
    ).toPreviewQuery(word: 'cat');
    expect(query.containsKey('sort'), isFalse);
    expect(query['word'], 'cat');
    expect(query['filter'], 'for_android');
  });

  test('illust-only filters serialize on illust, never on novel', () {
    const filters = SearchFilters(
      aiFilter: SearchAiFilter.exclude,
      bookmarkMin: 100,
      bookmarkMax: 5000,
      ratio: SearchRatioPattern.landscape,
      contentType: SearchContentType.ugoira,
      widthMin: 1024,
      widthMax: 4096,
      heightMin: 768,
      heightMax: 2160,
    );

    final illust = const IllustSearchQuery(
      keyword: 'cat',
      filters: filters,
    ).toQuery();
    expect(illust, {
      'word': 'cat',
      'search_target': 'partial_match_for_tags',
      'sort': 'date_desc',
      'filter': 'for_android',
      'search_ai_type': '1',
      'bookmark_num_min': '100',
      'bookmark_num_max': '5000',
      'ratio_pattern': 'landscape',
      'content_type': 'ugoira',
      'width_min': '1024',
      'width_max': '4096',
      'height_min': '768',
      'height_max': '2160',
    });

    final novel = const NovelSearchQuery(
      keyword: 'cat',
      filters: filters,
    ).toQuery();
    for (final key in [
      'ratio_pattern',
      'content_type',
      'width_min',
      'width_max',
      'height_min',
      'height_max',
    ]) {
      expect(novel.containsKey(key), isFalse, reason: key);
    }
    // Shared params do cross over — the novel endpoint accepts them.
    expect(novel['search_ai_type'], '1');
    expect(novel['bookmark_num_min'], '100');
  });

  test('gendered sorts normalize to popular_desc on the novel wire', () {
    for (final sort in [
      SearchSort.popularMaleDesc,
      SearchSort.popularFemaleDesc,
    ]) {
      final query = NovelSearchQuery(
        keyword: 'cat',
        filters: SearchFilters(sort: sort),
      ).toQuery();
      // The novel endpoint 400s on male/female sorts — never emit them.
      expect(query['sort'], 'popular_desc');
    }
    final illust = const IllustSearchQuery(
      keyword: 'cat',
      filters: SearchFilters(sort: SearchSort.popularMaleDesc),
    ).toQuery();
    expect(illust['sort'], 'popular_male_desc');
  });

  test('ai-only has no wire value; exclude serializes search_ai_type=1', () {
    final only = const IllustSearchQuery(
      keyword: 'cat',
      filters: SearchFilters(aiFilter: SearchAiFilter.only),
    ).toQuery();
    expect(only.containsKey('search_ai_type'), isFalse);

    final all = const IllustSearchQuery(
      keyword: 'cat',
      filters: SearchFilters(aiFilter: SearchAiFilter.all),
    ).toQuery();
    expect(all.containsKey('search_ai_type'), isFalse);
  });

  test('premium gendered sort stays on the full search endpoint', () async {
    final container = await _apiContainer((request) async {
      expect(request.url.path, '/v1/search/illust');
      expect(request.url.queryParameters['sort'], 'popular_male_desc');
      return _json({
        'illusts': [illustJson(63)],
        'next_url': null,
      });
    }, accountIsPremium: true);
    addTearDown(container.dispose);

    final page = await container
        .read(searchRepositoryProvider)
        .searchIllust(
          const IllustSearchQuery(
            keyword: 'cat',
            filters: SearchFilters(sort: SearchSort.popularMaleDesc),
          ),
        );
    expect(page.illusts.single.id, 63);
  });

  test('non-premium gendered sort reroutes to popular-preview', () async {
    final container = await _apiContainer((request) async {
      expect(request.url.path, '/v1/search/popular-preview/illust');
      expect(request.url.queryParameters.containsKey('sort'), isFalse);
      return _json({'illusts': <Object?>[], 'next_url': null});
    });
    addTearDown(container.dispose);

    await container
        .read(searchRepositoryProvider)
        .searchIllust(
          const IllustSearchQuery(
            keyword: 'cat',
            filters: SearchFilters(sort: SearchSort.popularFemaleDesc),
          ),
        );
  });

  test('search cursors accept the new filter parameters', () async {
    final container = await _apiContainer(
      (request) async => _json({'illusts': <Object?>[], 'next_url': null}),
    );
    addTearDown(container.dispose);
    final repository = container.read(searchRepositoryProvider);

    final cursor =
        'https://app-api.pixiv.net/v1/search/illust?'
        'word=cat&search_target=partial_match_for_tags&sort=date_desc&'
        'filter=for_android&search_ai_type=1&bookmark_num_min=100&'
        'ratio_pattern=portrait&content_type=manga&width_min=1024&offset=30';
    expect(
      repository.validateCursor(
        const IllustSearchQuery(
          keyword: 'cat',
          filters: SearchFilters(
            aiFilter: SearchAiFilter.exclude,
            bookmarkMin: 100,
            ratio: SearchRatioPattern.portrait,
            contentType: SearchContentType.manga,
            widthMin: 1024,
          ),
        ),
        cursor: cursor,
      ),
      isTrue,
    );
    // A pinned filter param mismatch belongs to another feed and is refused.
    expect(
      repository.validateCursor(
        const IllustSearchQuery(
          keyword: 'cat',
          filters: SearchFilters(
            aiFilter: SearchAiFilter.exclude,
            bookmarkMin: 200,
            ratio: SearchRatioPattern.portrait,
            contentType: SearchContentType.manga,
            widthMin: 1024,
          ),
        ),
        cursor: cursor,
      ),
      isFalse,
    );
  });

  test('search cache keys include the active filter set', () {
    const base = IllustSearchQuery(keyword: 'cat');
    final dated = IllustSearchQuery(
      keyword: 'cat',
      filters: SearchFilters(
        sort: SearchSort.dateAsc,
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 27),
      ),
    );
    final duration = IllustSearchQuery(
      keyword: 'cat',
      filters: SearchFilters(duration: SearchDuration.week),
    );

    expect(dated.cacheKey, isNot(base.cacheKey));
    expect(duration.cacheKey, isNot(base.cacheKey));
    expect(dated.cacheKey, contains('date_asc'));
    expect(dated.cacheKey, contains('2026-08-01'));
    expect(dated.cacheKey, contains('2026-08-27'));
  });

  test(
    'repository maps the three search endpoints and parses their pages',
    () async {
      final paths = <String>[];
      final container = await _apiContainer((request) async {
        paths.add(request.url.path);
        expect(request.url.queryParameters['word'], 'cat');
        expect(request.url.queryParameters['filter'], 'for_android');
        return switch (request.url.path) {
          '/v1/search/illust' => (() {
            expect(
              request.url.queryParameters['search_target'],
              'partial_match_for_tags',
            );
            return _json({
              'illusts': [illustJson(51)],
              'next_url': null,
            });
          })(),
          '/v1/search/novel' => _json({
            'novels': [
              {
                'id': 52,
                'title': 'novel result',
                'user': {
                  'id': 8,
                  'name': 'author',
                  'account': 'author',
                  'profile_image_urls': <String, String>{},
                },
              },
            ],
            'next_url': null,
          }),
          '/v1/search/user' => _json({
            'user_previews': [
              {
                'user': {
                  'id': 53,
                  'name': 'user result',
                  'account': 'result',
                  'profile_image_urls': <String, String>{},
                },
              },
            ],
            'next_url': null,
          }),
          _ => http.Response('unexpected path', 404),
        };
      });
      addTearDown(container.dispose);
      final repository = container.read(searchRepositoryProvider);
      final illust = await repository.searchIllust(
        const IllustSearchQuery(keyword: 'cat'),
      );
      final novel = await repository.searchNovel(
        const NovelSearchQuery(keyword: 'cat'),
      );
      final users = await repository.searchUsers(
        const UserSearchQuery(keyword: 'cat'),
      );

      expect(illust.illusts.single.id, 51);
      expect(novel.novels.single.id, 52);
      expect(users.users.single.id, 53);
      expect(paths, [
        '/v1/search/illust',
        '/v1/search/novel',
        '/v1/search/user',
      ]);
      final validCursor =
          'https://app-api.pixiv.net/v1/search/illust?'
          'word=cat&search_target=partial_match_for_tags&sort=date_desc&'
          'filter=for_android&offset=30';
      expect(
        repository.validateCursor(
          const IllustSearchQuery(keyword: 'cat'),
          cursor: validCursor,
        ),
        isTrue,
      );
      // The active search is pinned: a cursor for another keyword belongs to
      // another feed and is refused.
      expect(
        repository.validateCursor(
          const IllustSearchQuery(keyword: 'cat'),
          cursor: validCursor.replaceFirst('word=cat', 'word=dog'),
        ),
        isFalse,
      );
      // A parameter Pixiv added that this client has never seen is still the
      // same search and must keep paging.
      expect(
        repository.validateCursor(
          const IllustSearchQuery(keyword: 'cat'),
          cursor: '$validCursor&brand_new_flag=1',
        ),
        isTrue,
      );
    },
  );

  test(
    'non-premium popular sort reroutes to the popular-preview endpoint',
    () async {
      final container = await _apiContainer((request) async {
        expect(request.url.path, '/v1/search/popular-preview/illust');
        // The preview endpoint orders by popularity implicitly — sending a
        // sort parameter is rejected.
        expect(request.url.queryParameters.containsKey('sort'), isFalse);
        expect(request.url.queryParameters['word'], 'cat');
        return _json({
          'illusts': [illustJson(61)],
          'next_url': null,
        });
      });
      addTearDown(container.dispose);

      final page = await container
          .read(searchRepositoryProvider)
          .searchIllust(
            const IllustSearchQuery(
              keyword: 'cat',
              filters: SearchFilters(sort: SearchSort.popularDesc),
            ),
          );
      expect(page.illusts.single.id, 61);
    },
  );

  test('premium popular sort stays on the full search endpoint', () async {
    final container = await _apiContainer((request) async {
      expect(request.url.path, '/v1/search/illust');
      expect(request.url.queryParameters['sort'], 'popular_desc');
      return _json({
        'illusts': [illustJson(62)],
        'next_url': null,
      });
    }, accountIsPremium: true);
    addTearDown(container.dispose);

    final page = await container
        .read(searchRepositoryProvider)
        .searchIllust(
          const IllustSearchQuery(
            keyword: 'cat',
            filters: SearchFilters(sort: SearchSort.popularDesc),
          ),
        );
    expect(page.illusts.single.id, 62);
  });

  test(
    'non-premium popular novel search uses the novel preview endpoint',
    () async {
      final container = await _apiContainer((request) async {
        expect(request.url.path, '/v1/search/popular-preview/novel');
        expect(request.url.queryParameters.containsKey('sort'), isFalse);
        return _json({'novels': <Object?>[], 'next_url': null});
      });
      addTearDown(container.dispose);

      await container
          .read(searchRepositoryProvider)
          .searchNovel(
            const NovelSearchQuery(
              keyword: 'cat',
              filters: SearchFilters(sort: SearchSort.popularDesc),
            ),
          );
    },
  );

  test('repository uses the current autocomplete endpoint and query', () async {
    final container = await _apiContainer((request) async {
      expect(request.url.path, '/v2/search/autocomplete');
      expect(request.url.queryParameters, {
        'merge_plain_keyword_results': 'true',
        'word': 'cat',
      });
      return _json({
        'tags': [
          {'name': 'cat', 'translated_name': '猫'},
        ],
      });
    });
    addTearDown(container.dispose);

    final suggestions = await container
        .read(searchRepositoryProvider)
        .autocomplete('  cat  ');

    expect(suggestions, hasLength(1));
    expect(suggestions.single.keyword, 'cat');
    expect(suggestions.single.translatedName, '猫');
  });

  test(
    'search feed merges typed illust results into the shared store',
    () async {
      final repository = _FakeSearchRepository()
        ..illustPage = SearchIllustPage(
          illusts: [parseIllust(illustJson(42))],
          nextUrl: null,
        );
      final container = ProviderContainer(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final query = const IllustSearchQuery(keyword: 'cat');
      final state = await container.read(searchFeedProvider(query).future);
      expect(state.ids, [42]);
      expect(container.read(illustStoreProvider).get(42), isNotNull);
      expect(repository.requests, [query]);
    },
  );

  test(
    'autocomplete debounce suppresses a late response from an old query',
    () async {
      final oldResponse = Completer<List<SearchSuggestion>>();
      final newResponse = Completer<List<SearchSuggestion>>();
      final repository = _FakeSearchRepository(
        autocompleteHandler: (keyword, _) =>
            keyword == 'old' ? oldResponse.future : newResponse.future,
      );
      final container = ProviderContainer(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
      );
      final subscription = container.listen(
        searchAutocompleteProvider,
        (_, _) {},
      );
      addTearDown(() {
        subscription.close();
        container.dispose();
      });
      final controller = container.read(searchAutocompleteProvider.notifier);

      controller.update('old');
      await Future<void>.delayed(
        SearchAutocompleteController.debounceDuration +
            const Duration(milliseconds: 30),
      );
      controller.update('new');
      await Future<void>.delayed(
        SearchAutocompleteController.debounceDuration +
            const Duration(milliseconds: 30),
      );
      oldResponse.complete(const [SearchSuggestion(keyword: 'old-result')]);
      newResponse.complete(const [SearchSuggestion(keyword: 'new-result')]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final state = container.read(searchAutocompleteProvider);
      expect(state.keyword, 'new');
      expect(state.suggestions.single.keyword, 'new-result');
    },
  );

  test(
    'autocomplete disposal cancels pending work without publishing state',
    () async {
      final response = Completer<List<SearchSuggestion>>();
      final repository = _FakeSearchRepository(
        autocompleteHandler: (_, _) => response.future,
      );
      final container = ProviderContainer(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
      );
      final subscription = container.listen(
        searchAutocompleteProvider,
        (_, _) {},
      );
      final controller = container.read(searchAutocompleteProvider.notifier);
      controller.update('dispose-me');
      await Future<void>.delayed(
        SearchAutocompleteController.debounceDuration +
            const Duration(milliseconds: 30),
      );
      container.dispose();
      response.complete(const [SearchSuggestion(keyword: 'late')]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      subscription.close();
    },
  );

  testWidgets('search guide renders trending tags and the three input tabs', (
    tester,
  ) async {
    final repository = _FakeSearchRepository();
    final router = createPixivRouter(initialLocation: '/search');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('热门标签'), findsOneWidget);
    expect(find.text('#风景'), findsOneWidget);
    expect(find.text('#猫'), findsOneWidget);

    expect(find.byType(SearchBar), findsOneWidget);
    await tester.tap(find.byType(SearchBar));
    await tester.pumpAndSettle();
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(find.byType(SearchAnchor), findsNothing);
    expect(find.byType(SearchBar), findsOneWidget);
    expect(find.text('插画 & 漫画'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('用户'), findsOneWidget);
  });

  testWidgets('inline suggestions submit the existing typed query', (
    tester,
  ) async {
    final repository = _FakeSearchRepository(
      autocompleteHandler: (keyword, _) async => [
        SearchSuggestion(keyword: keyword, translatedName: '猫'),
      ],
    );
    final router = createPixivRouter(initialLocation: '/search/input');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'cat');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('猫'), findsOneWidget);
    await tester.tap(find.text('猫'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/search/results');
    expect(router.state.uri.queryParameters['q'], 'cat');
    expect(router.state.uri.queryParameters['type'], 'illust');
    expect(find.byType(SearchResultPage), findsOneWidget);
  });

  testWidgets('U2: a trending tag renders its representative image', (
    tester,
  ) async {
    final repository = _FakeSearchRepository();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [searchRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: const SearchHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    });

    // 风景 has a representative; 猫 does not. Exactly one image, and it uses
    // the square thumbnail rather than a full-size preview.
    final images = tester.widgetList<PixivImage>(find.byType(PixivImage));
    expect(images, hasLength(1));
    expect(images.single.url, 'https://i.pximg.net/901/square.jpg');
    expect(images.single.fit, BoxFit.cover);
    // The tagless card keeps the plain text form, no broken-image slot.
    expect(find.text('#猫'), findsOneWidget);
    expect(find.text('#风景'), findsOneWidget);
  });

  testWidgets('trending grid trims to complete rows of three', (tester) async {
    final repository = _FakeSearchRepository(trendingTagCount: 4);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),

          home: SearchHomePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('#标签3'), findsOneWidget);
    expect(find.text('#标签4'), findsNothing);
  });

  testWidgets('switching the trending kind re-requests the novel endpoint', (
    tester,
  ) async {
    final repository = _FakeSearchRepository();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [searchRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),

            home: SearchHomePage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(repository.trendingTagsLastType, SearchResultType.illust);

      await tester.tap(find.text('小说'));
      await tester.pump();
      await tester.pump();
    });
    expect(repository.trendingTagsLastType, SearchResultType.novel);
    expect(repository.trendingTagsCallCount, 2);
  });

  testWidgets('U2: tapping a trending tag still searches that tag', (
    tester,
  ) async {
    final repository = _FakeSearchRepository();
    final router = createPixivRouter(initialLocation: '/search');
    addTearDown(router.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [searchRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Adding the image must not turn the primary tap into "open the work".
      await tester.tap(find.text('#风景'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(SearchResultPage), findsOneWidget);
    expect(find.byType(IllustDetailPage), findsNothing);
  });

  testWidgets('U2: re-entering search does not re-request trending tags', (
    tester,
  ) async {
    final repository = _FakeSearchRepository();
    final showSearch = ValueNotifier<bool>(true);
    addTearDown(showSearch.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [searchRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

            home: ValueListenableBuilder<bool>(
              valueListenable: showSearch,
              builder: (context, visible, _) => visible
                  ? const SearchHomePage()
                  : const Scaffold(body: SizedBox.shrink()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(repository.trendingTagsCallCount, 1);

      // Fully unmount the page: with an autoDispose provider this removed the
      // last listener and the next visit re-requested the endpoint.
      showSearch.value = false;
      await tester.pumpAndSettle();
      showSearch.value = true;
      await tester.pumpAndSettle();
    });

    expect(repository.trendingTagsCallCount, 1);
    expect(find.text('#风景'), findsOneWidget);
  });

  testWidgets('typed result page uses the shared result route', (tester) async {
    final repository = _FakeSearchRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),

          home: const SearchResultPage(
            query: UserSearchQuery(keyword: 'not-an-id'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SearchResultPage), findsOneWidget);
  });
}
