import 'dart:async';

import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';

import 'illust_fixtures.dart';

class FakeSearchRepository implements SearchRepository {
  FakeSearchRepository({this.autocompleteHandler, this.trendingTagCount = 2});

  final Future<List<SearchSuggestion>> Function(
    String keyword,
    CancelToken? cancelToken,
  )?
  autocompleteHandler;
  final requests = <SearchQuery>[];

  /// When set, every search fetch awaits it — holds a result page's
  /// initial load in flight.
  Completer<void>? pendingFetch;

  SearchIllustPage illustPage = const SearchIllustPage(
    illusts: [],
    nextUrl: null,
  );

  SearchNovelPage novelPage = const SearchNovelPage(novels: [], nextUrl: null);

  @override
  Future<SearchIllustPage> searchIllust(
    IllustSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    await pendingFetch?.future;
    return illustPage;
  }

  @override
  Future<SearchNovelPage> searchNovel(
    NovelSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    await pendingFetch?.future;
    return novelPage;
  }

  @override
  Future<SearchUserPage> searchUsers(
    UserSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    await pendingFetch?.future;
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

  /// Holds every trendingTags call until completed.
  Completer<void>? trendingGate;

  @override
  Future<List<TrendingTag>> trendingTags({
    SearchResultType type = SearchResultType.illust,
    CancelToken? cancelToken,
  }) async {
    trendingTagsCallCount++;
    trendingTagsLastType = type;
    await trendingGate?.future;
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
