import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/search/search_autocomplete_controller.dart';
import 'package:parfait/core/search/search_feed_controller.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/features/search/search_filter_sheet.dart';
import 'package:parfait/features/search/search_input_page.dart';
import 'package:parfait/features/search/search_result_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/search_world.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler, {
  bool accountIsPremium = false,
  List<Override> extraOverrides = const [],
}) async {
  return signedInApiContainer(
    MockClient(handler),
    account: Account(
      id: 'account',
      userId: 8,
      name: 'tester',
      isPremium: accountIsPremium,
    ),
    overrides: extraOverrides,
  );
}

http.Response _json(Map<String, dynamic> value) => jsonResponse(value);

void main() {
  // Widget tests below build PixivImage, which reads SharedPreferencesAsync.
  // Without this they only passed when an earlier test in the file had set the
  // platform, and failed once `flutter test --total-shards` split the file.

  Future<GoRouter> pumpSearchRouter(
    WidgetTester tester,
    String location, {
    Map<String, ApiRoute> routes = const {},
  }) async {
    final router = pixivRouter(location);
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        container: await searchWorld(SearchApi(), routes: routes),
      ),
    );
    await tester.pump();
    await tester.pump();
    return router;
  }

  // Popular and gendered sorts need premium: without it a search reroutes to
  // popular-preview, which orders by popularity itself and rejects `sort`.
  const full = '/v1/search/illust';
  const preview = '/v1/search/popular-preview/illust';
  for (final (sort, premium, path, wireSort) in [
    (SearchSort.popularDesc, true, full, 'popular_desc'),
    (SearchSort.popularMaleDesc, true, full, 'popular_male_desc'),
    (SearchSort.popularDesc, false, preview, null),
    (SearchSort.popularFemaleDesc, false, preview, null),
  ]) {
    test(
      '${premium ? '' : 'non-'}premium ${sort.name} search calls $path',
      () async {
        final container = await _apiContainer((request) async {
          expect(request.url.path, path);
          expect(request.url.queryParameters['sort'], wireSort);
          expect(request.url.queryParameters['word'], 'cat');
          return _json({
            'illusts': [illustJson(61)],
            'next_url': null,
          });
        }, accountIsPremium: premium);

        final page = await container
            .read(searchRepositoryProvider)
            .searchIllust(
              IllustSearchQuery(
                keyword: 'cat',
                filters: IllustSearchFilters(sort: sort),
              ),
            );
        expect(page.illusts.single.id, 61);
      },
    );
  }

  test('search cursors accept the new filter parameters', () async {
    String? next;
    final container = await _apiContainer(
      (request) async => _json({'illusts': <Object?>[], 'next_url': next}),
      accountIsPremium: true,
    );
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
          filters: IllustSearchFilters(
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
    // A duration search's cursor keeps the range it began with: past local
    // midnight today's range differs, and the page must still load (R15).
    const day = IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(duration: SearchDuration.day),
    );
    const base =
        'https://app-api.pixiv.net/v1/search/illust?word=cat&'
        'search_target=partial_match_for_tags&sort=date_desc&filter=for_android';
    const ranged = '$base&start_date=2020-01-01&end_date=2020-01-02';
    expect(repository.validateCursor(day, cursor: ranged), isTrue);
    // Each next page keeps it too: other dates or none are refused.
    next = '$ranged&offset=30';
    expect((await repository.searchIllust(day, cursor: ranged)).nextUrl, next);
    for (final drifted in [
      '$base&offset=30',
      '$base&start_date=2020-01-02&end_date=2020-01-03&offset=30',
    ]) {
      next = drifted;
      await expectLater(
        repository.searchIllust(day, cursor: ranged),
        throwsA(isA<ApiParseError>()),
      );
    }
    // A pinned filter param mismatch belongs to another feed and is refused.
    expect(
      repository.validateCursor(
        const IllustSearchQuery(
          keyword: 'cat',
          filters: IllustSearchFilters(
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

  test(
    'free-account tag search synthesizes users入り OR groups and pins rewritten word on cursors',
    () async {
      final seen = <Uri>[];
      final container = await _apiContainer((request) async {
        seen.add(request.url);
        return _json({'illusts': <Object?>[], 'next_url': null});
      });
      final repository = container.read(searchRepositoryProvider);

      const query = IllustSearchQuery(
        keyword: 'cat',
        filters: IllustSearchFilters(
          target: SearchTarget.exactMatchForTags,
          bookmarkMin: 5000,
        ),
      );
      await repository.searchIllust(query);
      final params = seen.single.queryParameters;
      expect(
        params['word'],
        'cat (5000users入り OR 10000users入り OR 30000users入り OR 50000users入り OR 100000users入り)',
      );
      expect(params['search_target'], 'partial_match_for_tags');
      expect(params.containsKey('bookmark_num_min'), isFalse);

      final validCursor = Uri.https('app-api.pixiv.net', '/v1/search/illust', {
        ...params,
        'offset': '30',
      }).toString();
      expect(repository.validateCursor(query, cursor: validCursor), isTrue);
      expect(
        repository.validateCursor(
          query,
          cursor:
              'https://app-api.pixiv.net/v1/search/illust?word=cat&'
              'search_target=partial_match_for_tags&sort=date_desc&filter=for_android&offset=30',
        ),
        isFalse,
      );

      // Non-tag target skips synthesis and preserves original word.
      seen.clear();
      await repository.searchIllust(
        const IllustSearchQuery(
          keyword: 'cat',
          filters: IllustSearchFilters(
            target: SearchTarget.titleAndCaption,
            bookmarkMin: 5000,
          ),
        ),
      );
      expect(seen.single.queryParameters['word'], 'cat');
      expect(seen.single.queryParameters['search_target'], 'title_and_caption');
    },
  );

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
                'illusts': [for (var id = 61; id <= 64; id++) illustJson(id)],
              },
            ],
            'next_url': null,
          }),
          _ => http.Response('unexpected path', 404),
        };
      });
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
      expect(
        [for (final work in users.previewIllusts[53]!) work.id],
        [61, 62, 63],
      );
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

  test('a malformed preview fails the user search page (PAGE-05)', () async {
    final container = await _apiContainer(
      (request) async => _json({
        'user_previews': [
          {
            'user': {
              'id': 53,
              'name': 'user',
              'account': 'user',
              'profile_image_urls': <String, String>{},
            },
            'illusts': 'not a list',
          },
        ],
        'next_url': null,
      }),
    );

    await expectLater(
      container
          .read(searchRepositoryProvider)
          .searchUsers(const UserSearchQuery(keyword: 'cat')),
      throwsA(isA<ApiParseError>()),
    );
  });

  test(
    'non-premium popular novel search uses the novel preview endpoint',
    () async {
      final container = await _apiContainer((request) async {
        expect(request.url.path, '/v1/search/popular-preview/novel');
        expect(request.url.queryParameters.containsKey('sort'), isFalse);
        return _json({'novels': <Object?>[], 'next_url': null});
      });

      await container
          .read(searchRepositoryProvider)
          .searchNovel(
            const NovelSearchQuery(
              keyword: 'cat',
              filters: NovelSearchFilters(sort: SearchSort.popularDesc),
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
      final api = SearchApi()..illusts = [illustJson(42)];
      final container = await searchWorld(api);

      final query = const IllustSearchQuery(keyword: 'cat');
      final state = await container.read(searchFeedProvider(query).future);
      expect(state.ids, [42]);
      expect(container.read(illustStoreProvider).get(42), isNotNull);
      expect(
        [
          for (final request in api.requests)
            (request.url.path, request.url.queryParameters['word']),
        ],
        [('/v1/search/illust', 'cat')],
      );
    },
  );

  test(
    'search feed applies client-side bookmark and AI-only predicates',
    () async {
      final container = await searchWorld(
        SearchApi()
          ..illusts = [
            illustJson(1, totalBookmarks: 50),
            illustJson(2, totalBookmarks: 500, aiType: 2),
            illustJson(3, totalBookmarks: 5000, aiType: 2),
          ],
      );

      // bookmark_num_min is Premium-only on the wire — the client-side
      // predicate must still drop low-bookmark works on free accounts.
      final ranged = await container.read(
        searchFeedProvider(
          const IllustSearchQuery(
            keyword: 'cat',
            filters: IllustSearchFilters(bookmarkMin: 100),
          ),
        ).future,
      );
      expect(ranged.ids, [2, 3]);

      // "Only AI" has no wire value; filtering is entirely client-side.
      final aiOnly = await container.read(
        searchFeedProvider(
          const IllustSearchQuery(
            keyword: 'cat',
            filters: IllustSearchFilters(aiFilter: SearchAiFilter.only),
          ),
        ).future,
      );
      expect(aiOnly.ids, [2, 3]);

      final combined = await container.read(
        searchFeedProvider(
          const IllustSearchQuery(
            keyword: 'cat',
            filters: IllustSearchFilters(
              aiFilter: SearchAiFilter.only,
              bookmarkMin: 1000,
            ),
          ),
        ).future,
      );
      expect(combined.ids, [3]);
    },
  );

  test('search feed applies the same predicates to novel results', () async {
    final container = await searchWorld(
      SearchApi()
        ..novels = [
          novelJson(1, totalBookmarks: 50),
          novelJson(2, totalBookmarks: 500, novelAiType: 2),
          novelJson(3, totalBookmarks: 5000, novelAiType: 2),
        ],
    );

    // The client-side predicates run against the incoming page entities —
    // the same bookmark/AI rule as the illust feed, via novel_ai_type.
    final ranged = await container.read(
      searchFeedProvider(
        const NovelSearchQuery(
          keyword: 'cat',
          filters: NovelSearchFilters(bookmarkMin: 100),
        ),
      ).future,
    );
    expect(ranged.ids, [2, 3]);

    final aiOnly = await container.read(
      searchFeedProvider(
        const NovelSearchQuery(
          keyword: 'cat',
          filters: NovelSearchFilters(aiFilter: SearchAiFilter.only),
        ),
      ).future,
    );
    expect(aiOnly.ids, [2, 3]);
  });

  test(
    'autocomplete debounce suppresses a late response from an old query',
    () async {
      final oldResponse = Completer<List<SearchSuggestion>>();
      final newResponse = Completer<List<SearchSuggestion>>();
      final container = await searchWorld(
        SearchApi(
          autocomplete: (word) =>
              word == 'old' ? oldResponse.future : newResponse.future,
        ),
      );
      final subscription = container.listen(
        searchAutocompleteProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
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
      final container = await searchWorld(
        SearchApi(autocomplete: (_) => response.future),
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

  group('filter sheet bounds', () {
    const reversedError = '最小值不能大于最大值';

    Future<SearchFilterSheetResult? Function()> open(
      WidgetTester tester,
      SearchFilters initial,
    ) async {
      SearchFilterSheetResult? result;
      await tester.pumpWidget(
        localizedApp(
          home: ProviderScope(
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showSearchFilterSheet(
                      context,
                      initial: initial,
                      offerSetDefault: true,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => result;
    }

    Future<void> enter(WidgetTester tester, int field, String text) async {
      final finder = find.byType(TextField).at(field);
      await tester.ensureVisible(finder);
      await tester.enterText(finder, text);
      await tester.pump();
    }

    bool applyEnabled(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byType(FilledButton)).enabled;

    bool setDefaultEnabled(WidgetTester tester) =>
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).enabled;

    testWidgets('a reversed pair shows an error and blocks apply until '
        'fixed', (tester) async {
      final result = await open(tester, IllustSearchFilters.defaults);
      // Fields in order: bookmark, width, height — min then max.
      await enter(tester, 0, '500');
      await enter(tester, 1, '100');
      expect(find.text(reversedError), findsOneWidget);
      expect(applyEnabled(tester), isFalse);
      expect(setDefaultEnabled(tester), isFalse);
      // The field being typed in keeps focus as the error appears.
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).at(1))
            .focusNode
            .hasFocus,
        isTrue,
      );

      await enter(tester, 1, '1000');
      await tester.pumpAndSettle();
      expect(find.text(reversedError), findsNothing);
      expect(applyEnabled(tester), isTrue);

      // Only digits get in, so what shows is what applies.
      await enter(tester, 2, '-12.5');
      expect(find.text('125'), findsOneWidget);

      await tester.ensureVisible(find.text('应用'));
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      final filters = result()!.filters as IllustSearchFilters;
      expect((filters.bookmarkMin, filters.bookmarkMax), (500, 1000));
      expect(filters.widthMin, 125);
    });
  });

  testWidgets('result route parameters round-trip every filter field', (
    tester,
  ) async {
    await pumpSearchRouter(
      tester,
      '/search/results?q=cat&type=illust&target=exact_match_for_tags'
      '&sort=date_asc&duration=within_last_week&start=2026-08-01'
      '&end=2026-08-27&ai=exclude&bmin=100&bmax=5000&ratio=portrait'
      '&ct=manga&wmin=1024&wmax=4096&hmin=768&hmax=2160',
    );

    final page = tester.widget<SearchResultPage>(find.byType(SearchResultPage));
    final query = page.query as IllustSearchQuery;
    // Every field decodes, and the route describes the same feed identity as
    // a query built in code: cache keys must agree or restoration would fork
    // the feed.
    final built = IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(
        target: SearchTarget.exactMatchForTags,
        sort: SearchSort.dateAsc,
        duration: SearchDuration.week,
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 27),
        aiFilter: SearchAiFilter.exclude,
        bookmarkMin: 100,
        bookmarkMax: 5000,
        ratio: SearchRatioPattern.portrait,
        contentType: SearchContentType.manga,
        widthMin: 1024,
        widthMax: 4096,
        heightMin: 768,
        heightMax: 2160,
      ),
    );
    expect(query, built);
    expect(query.cacheKey, built.cacheKey);
  });

  testWidgets('malformed filter values fall back to defaults per field', (
    tester,
  ) async {
    await pumpSearchRouter(
      tester,
      '/search/results?q=cat&type=illust&sort=nonsense&ai=bogus'
      '&bmin=abc&ct=not-a-type&ratio=diagonal&start=not-a-date'
      '&wmin=-5&hmin=900&hmax=600',
    );

    final page = tester.widget<SearchResultPage>(find.byType(SearchResultPage));
    final filters = (page.query as IllustSearchQuery).filters;
    // One damaged field falls back to its default without discarding the
    // rest — same permissive rule as IllustSearchFilters.fromJson.
    expect(filters.sort, SearchSort.dateDesc);
    expect(filters.aiFilter, SearchAiFilter.all);
    expect(filters.bookmarkMin, isNull);
    expect(filters.contentType, SearchContentType.illustAndMangaAndUgoira);
    expect(filters.ratio, isNull);
    expect(filters.startDate, isNull);
    // Bounds decode like stored ones: a negative bound is dropped and a
    // reversed pair is put in order rather than failing the search.
    expect(filters.widthMin, isNull);
    expect((filters.heightMin, filters.heightMax), (600, 900));
    expect(page.query.cacheKey, isNotNull);
  });

  testWidgets('search input keeps its geometry when the IME opens', (
    tester,
  ) async {
    await pumpSearchRouter(tester, '/search/input');

    expect(find.byType(SearchInputPage), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(
      find.descendant(
        of: find.byType(SearchInputPage),
        matching: find.byType(Scaffold),
      ),
    );
    expect(scaffold.resizeToAvoidBottomInset, isFalse);
  });
}
