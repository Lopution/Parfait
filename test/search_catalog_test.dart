import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/search/search_autocomplete_controller.dart';
import 'package:parfait/core/search/search_feed_controller.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/search/search_filter_sheet.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/search_world.dart';
import 'helpers/test_preferences.dart';

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler, {
  bool accountIsPremium = false,
  List<Override> extraOverrides = const [],
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
      ...extraOverrides,
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
  // Widget tests below build PixivImage, which reads SharedPreferencesAsync.
  // Without this they only passed when an earlier test in the file had set the
  // platform, and failed once `flutter test --total-shards` split the file.
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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
            filters: IllustSearchFilters(sort: SearchSort.popularMaleDesc),
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
            filters: IllustSearchFilters(sort: SearchSort.popularFemaleDesc),
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
              filters: IllustSearchFilters(sort: SearchSort.popularDesc),
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
            filters: IllustSearchFilters(sort: SearchSort.popularDesc),
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
      final repository = FakeSearchRepository()
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
    'search feed applies client-side bookmark and AI-only predicates',
    () async {
      final repository = FakeSearchRepository()
        ..illustPage = SearchIllustPage(
          illusts: [
            parseIllust(illustJson(1, totalBookmarks: 50)),
            parseIllust(illustJson(2, totalBookmarks: 500, aiType: 2)),
            parseIllust(illustJson(3, totalBookmarks: 5000, aiType: 2)),
          ],
          nextUrl: null,
        );
      final container = ProviderContainer(
        overrides: [searchRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

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
    NovelEntity novel(int id, {int totalBookmarks = 0, int novelAiType = 0}) =>
        NovelEntity(
          id: id,
          title: 'novel $id',
          caption: '',
          user: const UserEntity(id: 8, name: 'author', account: 'author'),
          tags: const [],
          textLength: 1200,
          contentVersion: 'v$id',
          paragraphs: const [],
          totalBookmarks: totalBookmarks,
          novelAiType: novelAiType,
        );

    final repository = FakeSearchRepository()
      ..novelPage = SearchNovelPage(
        novels: [
          novel(1, totalBookmarks: 50),
          novel(2, totalBookmarks: 500, novelAiType: 2),
          novel(3, totalBookmarks: 5000, novelAiType: 2),
        ],
        nextUrl: null,
      );
    final container = ProviderContainer(
      overrides: [searchRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

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
      final repository = FakeSearchRepository(
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
      final repository = FakeSearchRepository(
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

  testWidgets('filter sheet renders illust groups and returns selections', (
    tester,
  ) async {
    SearchFilterSheetResult? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: ProviderScope(
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showSearchFilterSheet(
                    context,
                    initial: IllustSearchFilters.defaults,
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

    for (final section in ['AI 作品', '收藏数', '纵横比', '作品类别', '分辨率']) {
      expect(find.text(section), findsOneWidget, reason: section);
    }

    Future<void> tapLabel(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.pump();
      await tester.tap(find.text(text));
      await tester.pump();
    }

    await tapLabel('排除 AI');
    await tapLabel('纵向');
    await tapLabel('仅漫画');

    await tester.enterText(find.widgetWithText(TextField, '最小').first, '100');
    await tester.pump();

    await tester.ensureVisible(find.text('应用'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.makeDefault, isFalse);
    final filters = result!.filters as IllustSearchFilters;
    expect(filters.aiFilter, SearchAiFilter.exclude);
    expect(filters.ratio, SearchRatioPattern.portrait);
    expect(filters.contentType, SearchContentType.manga);
    expect(filters.bookmarkMin, 100);
    expect(filters.bookmarkMax, isNull);
  });

  group('filter sheet bounds', () {
    const reversedError = '最小值不能大于最大值';

    Future<SearchFilterSheetResult? Function()> open(
      WidgetTester tester,
      SearchFilters initial,
    ) async {
      SearchFilterSheetResult? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
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

    testWidgets('a stored reversed pair opens ordered', (tester) async {
      // What a pre-check sheet saved, read back as the app reads settings.
      await open(
        tester,
        IllustSearchFilters.fromJson({'bookmarkMin': 500, 'bookmarkMax': 100}),
      );
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .map((field) => field.controller!.text)
          .take(2);
      expect(fields, ['100', '500']);
      expect(find.text(reversedError), findsNothing);
    });
  });

  testWidgets('the guide camera opens reverse image search; the novel tab '
      'searches novels', (tester) async {
    final repository = FakeSearchRepository();
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
    await tester.pumpAndSettle();
    // The full-width reverse-image button is gone; the camera replaces it.
    expect(find.byType(FilledButton), findsNothing);

    await tester.tap(find.byTooltip('反向搜图'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/reverse-image');
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(Tab, '小说'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBar), matching: find.text('搜索')),
    );
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/search/input');
    expect(router.state.uri.queryParameters['type'], 'novel');
  });

  testWidgets('search input keeps its geometry when the IME opens', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
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
    await tester.pump();
    await tester.pump();

    expect(find.byType(SearchInputPage), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(
      find.descendant(
        of: find.byType(SearchInputPage),
        matching: find.byType(Scaffold),
      ),
    );
    expect(scaffold.resizeToAvoidBottomInset, isFalse);
  });

  for (final tab in ['插画 & 漫画', '小说']) {
    testWidgets('long-pressing a $tab trending tag opens its representative '
        'work', (tester) async {
      // The opened detail page tracks page visibility; post-frame updates
      // leave no timer behind when the test ends on the push.
      final interval = VisibilityDetectorController.instance.updateInterval;
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      addTearDown(
        () => VisibilityDetectorController.instance.updateInterval = interval,
      );
      final haptics = recordHaptics();
      final repository = FakeSearchRepository();
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
        await tester.tap(find.widgetWithText(Tab, tab));
        await tester.pumpAndSettle();

        await tester.longPress(find.text('#风景').hitTestable());
        await tester.pump();
      });
      expect(haptics.roles, [HapticRole.longPress]);
      expect(router.state.uri.path, '/search/illust/901');
    });
  }

  for (final (count, shown) in const [(2, 2), (3, 3), (4, 3), (5, 3), (7, 6)]) {
    testWidgets('$count trending tags show $shown: whole rows only', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = FakeSearchRepository(trendingTagCount: count);
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

      // Three columns at this width; fewer tags than a row still show.
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);
      expect(find.textContaining('#'), findsNWidgets(shown));
    });
  }

  testWidgets('switching the trending kind re-requests the novel endpoint', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
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
      expect(repository.trendingTagsCallCount, 1);

      await tester.tap(find.widgetWithText(Tab, '小说'));
      await tester.pumpAndSettle();
      // Each tab keeps its own list; switching back does not re-request.
      await tester.tap(find.widgetWithText(Tab, '插画 & 漫画'));
      await tester.pumpAndSettle();
    });
    expect(repository.trendingTagsLastType, SearchResultType.novel);
    expect(repository.trendingTagsCallCount, 2);
  });

  testWidgets('U2: tapping a trending tag still searches that tag', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
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
    final repository = FakeSearchRepository();
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

  testWidgets('result route parameters round-trip every filter field', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
    final router = createPixivRouter(
      initialLocation:
          '/search/results?q=cat&type=illust&target=exact_match_for_tags'
          '&sort=date_asc&duration=within_last_week&start=2026-08-01'
          '&end=2026-08-27&ai=exclude&bmin=100&bmax=5000&ratio=portrait'
          '&ct=manga&wmin=1024&wmax=4096&hmin=768&hmax=2160',
    );
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

    final page = tester.widget<SearchResultPage>(find.byType(SearchResultPage));
    final query = page.query as IllustSearchQuery;
    const expected = IllustSearchFilters(
      target: SearchTarget.exactMatchForTags,
      sort: SearchSort.dateAsc,
      duration: SearchDuration.week,
      aiFilter: SearchAiFilter.exclude,
      bookmarkMin: 100,
      bookmarkMax: 5000,
      ratio: SearchRatioPattern.portrait,
      contentType: SearchContentType.manga,
      widthMin: 1024,
      widthMax: 4096,
      heightMin: 768,
      heightMax: 2160,
    );
    final filters = query.filters;
    expect(filters.target, expected.target);
    expect(filters.sort, expected.sort);
    expect(filters.duration, expected.duration);
    expect(filters.startDate, DateTime(2026, 8, 1));
    expect(filters.endDate, DateTime(2026, 8, 27));
    expect(filters.aiFilter, expected.aiFilter);
    expect(filters.bookmarkMin, expected.bookmarkMin);
    expect(filters.bookmarkMax, expected.bookmarkMax);
    expect(filters.ratio, expected.ratio);
    expect(filters.contentType, expected.contentType);
    expect(filters.widthMin, expected.widthMin);
    expect(filters.widthMax, expected.widthMax);
    expect(filters.heightMin, expected.heightMin);
    expect(filters.heightMax, expected.heightMax);

    // The decoded route describes the same feed identity as a query built
    // in code — cache keys must agree or restoration would fork the feed.
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
    expect(query.cacheKey, built.cacheKey);
  });

  testWidgets('malformed filter values fall back to defaults per field', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
    final router = createPixivRouter(
      initialLocation:
          '/search/results?q=cat&type=illust&sort=nonsense&ai=bogus'
          '&bmin=abc&ct=not-a-type&ratio=diagonal&start=not-a-date'
          '&wmin=-5&hmin=900&hmax=600',
    );
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

  testWidgets('re-tapping the search destination scrolls the guide to top', (
    tester,
  ) async {
    final repository = FakeSearchRepository(trendingTagCount: 30);
    final router = createPixivRouter(initialLocation: '/search');
    addTearDown(router.dispose);
    // Compact viewport: at ≥600px the shell swaps the bottom bar for a
    // rail and FuncShellBottomNav leaves the tree.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchRepositoryProvider.overrideWithValue(repository),
            ...accountProviderOverrides(
              credentialStore: FakeCredentialStore(
                values: const {
                  '100': Credential(
                    accessToken: 'a-100',
                    refreshToken: 'r-100',
                  ),
                },
              ),
              metadataRepository: FakeAccountMetadataRepository(
                accounts: const [
                  Account(id: '100', userId: 100, name: 'tester'),
                ],
                currentId: '100',
              ),
            ),
          ],
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
      await tester.pumpAndSettle();

      final feedView = find.byKey(const PageStorageKey('search-home-illust'));
      expect(feedView, findsOneWidget);
      final controller = tester.widget<CustomScrollView>(feedView).controller!;
      controller.jumpTo(500);
      await tester.pump();
      expect(controller.offset, 500);

      // Snapshot rather than a literal: the provider re-fires once when the
      // account id lands asynchronously — that is hydration, not the re-tap.
      final callsBefore = repository.trendingTagsCallCount;
      await tester.tap(
        find.descendant(
          of: find.byType(FuncShellBottomNav),
          matching: find.byIcon(AppIcons.search),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
      // Pure scroll — the re-tap itself causes no refresh or re-request.
      expect(repository.trendingTagsCallCount, callsBefore);
    });
  });

  testWidgets('the result title reopens the input prefilled with the query', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
    final router = createPixivRouter(
      initialLocation: '/search/results?q=%E9%A3%8E%E6%99%AF&type=illust',
    );
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

    expect(find.byType(SearchResultPage), findsOneWidget);
    await tester.tap(find.text('风景'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(router.state.uri.path, '/search/input');
    expect(router.state.uri.queryParameters['q'], '风景');
    expect(router.state.uri.queryParameters['type'], 'illust');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '风景',
    );
  });

  testWidgets('an empty result keeps the header and offers modify-search', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
    final router = createPixivRouter(
      initialLocation: '/search/results?q=nothing&type=illust',
    );
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
    await tester.pumpAndSettle();

    // Query context stays visible on the empty surface, and the page
    // offers a direct edit entry — not just a blind refresh.
    expect(find.text('nothing'), findsOneWidget);
    expect(find.text('修改搜索'), findsOneWidget);
    await tester.tap(find.text('修改搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchInputPage), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'nothing',
    );
  });

  testWidgets('the filter summary row chips and clears active filters', (
    tester,
  ) async {
    final repository = FakeSearchRepository();
    final router = createPixivRouter(
      initialLocation:
          '/search/results?q=cat&type=illust&sort=date_asc&bmin=100',
    );
    addTearDown(router.dispose);
    // Wide surface: the AppBar-bottom chip row fits without scrolling, so
    // the trailing reset chip's centre is a clean tap target.
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await tester.pumpAndSettle();

    // Active fields surface as chips next to the persistent clear entry.
    expect(find.text('收藏数 100 以上'), findsOneWidget);
    expect(find.text('重置'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, '重置'));
    await tester.pumpAndSettle();
    // Clearing replaces the route: the URL no longer carries the bounds.
    expect(router.state.uri.queryParameters.containsKey('bmin'), isFalse);
    expect(router.state.uri.queryParameters['sort'], 'date_desc');
    expect(router.state.uri.queryParameters['q'], 'cat');
  });
}
