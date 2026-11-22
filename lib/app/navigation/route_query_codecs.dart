import 'package:go_router/go_router.dart';

import '../../core/bookmark/bookmark_models.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/illust/recommended_repository.dart';
import '../../core/network/api_date.dart';
import '../../core/new/new_feed_models.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/search/search_models.dart';
import '../../core/user/user_repository.dart';

/// `?mode=` of the ranking routes; null (absent or unknown) lets the page
/// open on the last category viewed.
RankingMode? rankingModeFromQuery(String? raw) =>
    RankingMode.values.asNameMap()[raw];

NovelRankingMode? novelRankingModeFromQuery(String? raw) =>
    NovelRankingMode.values.asNameMap()[raw];

/// `?date=` of the ranking routes: anything but a pickable past day is the
/// latest ranking.
DateTime? rankingDateFromState(GoRouterState state) =>
    rankingDateOrLatest(parseApiDate(state.uri.queryParameters['date']));

Map<String, String> rankingQueryParameters(String mode, DateTime? date) => {
  'mode': mode,
  if (date != null) 'date': formatApiDate(date),
};

RecommendedContentType recommendedTypeFromQuery(String? raw) =>
    RecommendedContentType.values.firstWhere(
      (type) => type.name == raw,
      orElse: () => RecommendedContentType.illust,
    );

NewFeedScope newFeedScopeFromQuery(String? raw) => switch (raw?.toLowerCase()) {
  'everyone' || 'all' => NewFeedScope.everyone,
  'mypixiv' || 'my_pixiv' => NewFeedScope.myPixiv,
  'following' || 'follow' || _ => NewFeedScope.following,
};

SearchResultType searchTypeFromQuery(String? raw) =>
    SearchResultType.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => SearchResultType.illust,
    );

/// Extracts the active `(keyword, type)` pair when [uri] points at a search
/// results or tag feed route, or `null` on any other location.
({String keyword, SearchResultType type})? searchResultsQueryFromUri(Uri uri) {
  if (uri.path.endsWith('/search/results')) {
    return (
      keyword: uri.queryParameters['q'] ?? '',
      type: searchTypeFromQuery(uri.queryParameters['type']),
    );
  }
  final segments = uri.path.split('/');
  if (segments.length >= 3 && segments[segments.length - 2] == 'tag') {
    final rawTag = segments.last;
    if (rawTag.isNotEmpty) {
      String keyword;
      try {
        keyword = Uri.decodeComponent(rawTag);
      } on FormatException {
        keyword = rawTag;
      }
      return (
        keyword: keyword,
        type: searchTypeFromQuery(uri.queryParameters['type']),
      );
    }
  }
  return null;
}

T _searchEnum<T>(
  Iterable<T> values,
  String? raw,
  String Function(T value) wireValue,
  T fallback,
) => values.firstWhere(
  (value) => wireValue(value) == raw,
  orElse: () => fallback,
);

/// The bound pair under [minKey]/[maxKey], through
/// `SearchFilters.decodeBounds`; a value that is not an integer counts as
/// unset.
(int?, int?) _searchBounds(
  Map<String, String> params,
  String minKey,
  String maxKey,
) {
  int? intOf(String key) => switch (params[key]) {
    final raw? => int.tryParse(raw),
    null => null,
  };
  return SearchFilters.decodeBounds(intOf(minKey), intOf(maxKey));
}

typedef _SharedSearchParams = ({
  SearchTarget target,
  SearchSort sort,
  SearchDuration? duration,
  DateTime? startDate,
  DateTime? endDate,
  SearchAiFilter aiFilter,
  int? bookmarkMin,
  int? bookmarkMax,
});

/// Every `SearchFilters` field is a route parameter so a result URL fully
/// describes the query (refresh/share/process-death all restore it).
/// Decoding is permissive per field — one damaged value falls back to its
/// default without discarding the rest, same rule as
/// `SearchFilters.fromJson`.
_SharedSearchParams _sharedSearchParams(Map<String, String> params) {
  final (bookmarkMin, bookmarkMax) = _searchBounds(params, 'bmin', 'bmax');
  return (
    target: _searchEnum(
      SearchTarget.values,
      params['target'],
      (value) => value.wireValue,
      SearchTarget.partialMatchForTags,
    ),
    sort: _searchEnum(
      SearchSort.values,
      params['sort'],
      (value) => value.wireValue,
      SearchSort.dateDesc,
    ),
    duration: _searchDuration(params['duration']),
    startDate: parseApiDate(params['start']),
    endDate: parseApiDate(params['end']),
    // `ai` serializes by enum name: `all`/`only` share the same (null) wire
    // value because `only` is enforced client-side.
    aiFilter: _searchEnum(
      SearchAiFilter.values,
      params['ai'],
      (value) => value.name,
      SearchAiFilter.all,
    ),
    bookmarkMin: bookmarkMin,
    bookmarkMax: bookmarkMax,
  );
}

IllustSearchFilters _illustSearchFilters(Map<String, String> params) {
  final shared = _sharedSearchParams(params);
  final (widthMin, widthMax) = _searchBounds(params, 'wmin', 'wmax');
  final (heightMin, heightMax) = _searchBounds(params, 'hmin', 'hmax');
  return IllustSearchFilters(
    // A foreign target in a shared URL clamps to the type's own set — the
    // novel-only `text`/`keyword` values can never reach an illust query.
    target: SearchFilters.clampTarget(
      shared.target,
      IllustSearchFilters.defaults.targetOptions,
    ),
    sort: shared.sort,
    duration: shared.duration,
    startDate: shared.startDate,
    endDate: shared.endDate,
    aiFilter: shared.aiFilter,
    bookmarkMin: shared.bookmarkMin,
    bookmarkMax: shared.bookmarkMax,
    ratio: _searchRatio(params['ratio']),
    contentType: _searchEnum(
      SearchContentType.values,
      params['ct'],
      (value) => value.wireValue,
      SearchContentType.illustAndMangaAndUgoira,
    ),
    widthMin: widthMin,
    widthMax: widthMax,
    heightMin: heightMin,
    heightMax: heightMax,
  );
}

NovelSearchFilters _novelSearchFilters(Map<String, String> params) {
  final shared = _sharedSearchParams(params);
  final (textLengthMin, textLengthMax) = _searchBounds(params, 'tmin', 'tmax');
  return NovelSearchFilters(
    target: SearchFilters.clampTarget(
      shared.target,
      NovelSearchFilters.defaults.targetOptions,
    ),
    // The novel endpoint does not recognize the gendered popularity sorts.
    sort: shared.sort.novelSafe,
    duration: shared.duration,
    startDate: shared.startDate,
    endDate: shared.endDate,
    aiFilter: shared.aiFilter,
    bookmarkMin: shared.bookmarkMin,
    bookmarkMax: shared.bookmarkMax,
    textLengthMin: textLengthMin,
    textLengthMax: textLengthMax,
    originalOnly: params['original'] == '1' || params['original'] == 'true',
  );
}

/// Decodes a full [SearchQuery] (including filter params) from [uri].
SearchQuery searchQueryFromUri(Uri uri) {
  final params = uri.queryParameters;
  final keyword = params['q'] ?? '';
  return switch (searchTypeFromQuery(params['type'])) {
    SearchResultType.illust => IllustSearchQuery(
      keyword: keyword,
      filters: _illustSearchFilters(params),
    ),
    SearchResultType.novel => NovelSearchQuery(
      keyword: keyword,
      filters: _novelSearchFilters(params),
    ),
    // A user search has no filters: the route carries none, and any stray
    // filter params on a shared URL are ignored rather than stored.
    SearchResultType.user => UserSearchQuery(keyword: keyword),
  };
}

/// Returns the full [SearchQuery] when [uri] points at a `/search/results`
/// route, or `null` otherwise (including `/tag/...` routes without filters).
SearchQuery? searchResultsFullQueryFromUri(Uri uri) =>
    uri.path.endsWith('/search/results') ? searchQueryFromUri(uri) : null;

SearchQuery searchQueryFromState(GoRouterState state) =>
    searchQueryFromUri(state.uri);

Map<String, String> _sharedFilterQueryParams(SearchFilters filters) => {
  'target': filters.normalizedTarget.wireValue,
  'sort': filters.normalizedSort.wireValue,
  if (filters.duration != null) 'duration': filters.duration!.wireValue,
  if (filters.startDate != null) 'start': formatApiDate(filters.startDate!),
  if (filters.endDate != null) 'end': formatApiDate(filters.endDate!),
  // Non-nullable selectors always serialize so the URL is
  // self-describing; `ai` uses the enum name because `all`/`only`
  // share the null wire value.
  'ai': filters.aiFilter.name,
  if (filters.bookmarkMin != null) 'bmin': '${filters.bookmarkMin}',
  if (filters.bookmarkMax != null) 'bmax': '${filters.bookmarkMax}',
};

Map<String, String> searchQueryParameters(SearchQuery query) => {
  'q': query.keyword,
  'type': query.type.name,
  ...switch (query) {
    IllustSearchQuery(:final filters) => {
      ..._sharedFilterQueryParams(filters),
      if (filters.ratio != null) 'ratio': filters.ratio!.wireValue,
      'ct': filters.contentType.wireValue,
      if (filters.widthMin != null) 'wmin': '${filters.widthMin}',
      if (filters.widthMax != null) 'wmax': '${filters.widthMax}',
      if (filters.heightMin != null) 'hmin': '${filters.heightMin}',
      if (filters.heightMax != null) 'hmax': '${filters.heightMax}',
    },
    NovelSearchQuery(:final filters) => {
      ..._sharedFilterQueryParams(filters),
      if (filters.textLengthMin != null) 'tmin': '${filters.textLengthMin}',
      if (filters.textLengthMax != null) 'tmax': '${filters.textLengthMax}',
      if (filters.originalOnly) 'original': '1',
    },
    // A user search has no filters to carry.
    UserSearchQuery() => const <String, String>{},
  },
};

SearchDuration? _searchDuration(String? raw) {
  for (final value in SearchDuration.values) {
    if (value.wireValue == raw) return value;
  }
  return null;
}

SearchRatioPattern? _searchRatio(String? raw) {
  for (final value in SearchRatioPattern.values) {
    if (value.wireValue == raw) return value;
  }
  return null;
}

BookmarkRestrict bookmarkRestrictFromQuery(String? restrict) =>
    restrict == BookmarkRestrict.private.name
    ? BookmarkRestrict.private
    : BookmarkRestrict.public;

/// Illustrations unless the location names novels: older locations carry
/// no kind.
BookmarkEntityType bookmarkKindFromQuery(String? kind) =>
    kind == BookmarkEntityType.novel.name
    ? BookmarkEntityType.novel
    : BookmarkEntityType.illust;

BookmarkRestrict bookmarkRestrictFromUser(UserRestrict restrict) =>
    switch (restrict) {
      UserRestrict.public => BookmarkRestrict.public,
      UserRestrict.private => BookmarkRestrict.private,
    };
