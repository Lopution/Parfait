import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/search/search_repository.dart';

import 'api_responses.dart';
import 'fake_account.dart';
import 'illust_fixtures.dart';

/// The App API's search endpoints. Every search answers [illusts] or
/// [novels] (App API JSON) as its one page, and no users; [requests] logs
/// each search from the wire. Trending tags answer [trendingTagCount] tags
/// (at least two), or [trendingTagNames], the first with work 901 as its
/// picture; autocomplete answers [autocomplete]'s suggestions for the word
/// sent.
class SearchApi {
  SearchApi({
    this.autocomplete,
    this.trendingTagCount = 2,
    this.trendingTagNames,
  });

  final Future<List<SearchSuggestion>> Function(String word)? autocomplete;
  final int trendingTagCount;
  final List<String>? trendingTagNames;
  final requests = <http.Request>[];

  /// When set, every search answer waits on it — holds a result page's
  /// initial load in flight.
  Completer<void>? pendingFetch;
  List<Map<String, dynamic>> illusts = const [];
  List<Map<String, dynamic>> novels = const [];

  /// Trending tag reads from the wire, by kind: `illust`, `novel`.
  final trendingRequests = <String>[];

  /// Holds every trending tag answer until completed.
  Completer<void>? trendingGate;

  ApiRoute _search(String key, List<Object?> Function() items) =>
      (request) async {
        requests.add(request);
        await pendingFetch?.future;
        return jsonResponse(pageJson(key, items()));
      };

  ApiRoute _trending(String kind) => (request) async {
    trendingRequests.add(kind);
    await trendingGate?.future;
    final names =
        trendingTagNames ??
        ['风景', '猫', for (var i = 2; i < trendingTagCount; i++) '标签${i + 1}'];
    return jsonResponse({
      'trend_tags': [
        for (final (i, name) in names.indexed)
          {'tag': name, if (i == 0) 'illust': illustJson(901)},
      ],
    });
  };

  Map<String, ApiRoute> get routes => {
    for (final path in [
      '/v1/search/illust',
      '/v1/search/popular-preview/illust',
    ])
      path: _search('illusts', () => illusts),
    for (final path in ['/v1/search/novel', '/v1/search/popular-preview/novel'])
      path: _search('novels', () => novels),
    '/v1/search/user': _search('user_previews', () => const []),
    '/v1/trending-tags/illust': _trending('illust'),
    '/v1/trending-tags/novel': _trending('novel'),
    '/v2/search/autocomplete': (request) async {
      final word = request.url.queryParameters['word']!;
      final suggestions =
          await autocomplete?.call(word) ?? const <SearchSuggestion>[];
      return jsonResponse({
        'tags': [
          for (final suggestion in suggestions)
            {
              'name': suggestion.keyword,
              'translated_name': ?suggestion.translatedName,
            },
        ],
      });
    },
  };
}

/// Signed in as [account] over [PixivApi] with [search]'s routes, the
/// shell's ([shellRoutes]) and [routes].
Future<ProviderContainer> searchWorld(
  SearchApi search, {
  Map<String, ApiRoute> routes = const {},
  Account account = testerAccount,
  List<Override> overrides = const [],
}) => signedInApiContainer(
  PixivApi({
    ...backgroundRoutes,
    ...shellRoutes,
    ...search.routes,
    ...routes,
  }).client,
  account: account,
  overrides: overrides,
);
