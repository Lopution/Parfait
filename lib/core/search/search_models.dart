/// Typed search selectors and wire values shared by search repositories/pages.
/// This library owns enum-to-wire mappings; query UI state belongs to the
/// search controllers. See `frontend/type-safety.md`.
library;

import 'package:flutter/foundation.dart';

/// The result tabs exposed by the beta56 search input page.
enum SearchResultType { illust, novel, user }

extension SearchResultTypeWire on SearchResultType {
  String get labelKey => switch (this) {
    SearchResultType.illust => 'searchIllustManga',
    SearchResultType.novel => 'searchNovel',
    SearchResultType.user => 'searchUser',
  };
}

/// Pixiv's typed `search_target` values. Unknown values never enter a
/// request because callers can only construct this enum.
enum SearchTarget {
  partialMatchForTags('partial_match_for_tags', 'searchPartialTags'),
  exactMatchForTags('exact_match_for_tags', 'searchExactTags'),
  titleAndCaption('title_and_caption', 'searchTitleCaption');

  const SearchTarget(this.wireValue, this.labelKey);

  final String wireValue;
  final String labelKey;
}

enum SearchSort {
  dateDesc('date_desc', 'searchDateDesc'),
  dateAsc('date_asc', 'searchDateAsc'),
  popularDesc('popular_desc', 'searchPopularDesc'),
  popularMaleDesc('popular_male_desc', 'searchPopularMaleDesc'),
  popularFemaleDesc('popular_female_desc', 'searchPopularFemaleDesc');

  const SearchSort(this.wireValue, this.labelKey);

  final String wireValue;
  final String labelKey;

  /// All popularity sorts are Premium-only server-side; free accounts are
  /// rerouted to the popular-preview endpoint by the repository.
  bool get isPopular =>
      this == popularDesc ||
      this == popularMaleDesc ||
      this == popularFemaleDesc;

  /// The novel endpoint does not recognize the gendered popularity sorts
  /// (400 Invalid value) — normalize to the closest semantic value before
  /// serializing, like Shaft's `SortType.novelSafe`.
  SearchSort get novelSafe => isPopular ? popularDesc : this;
}

/// AI-work selector. Pixiv's `search_ai_type` is binary (0=all, 1=exclude);
/// "only AI" has no wire value and is applied client-side on
/// `illust_ai_type == 2` in the search feed's page filter.
enum SearchAiFilter {
  all('searchAiAll'),
  exclude('searchAiExclude'),
  only('searchAiOnly');

  const SearchAiFilter(this.labelKey);

  final String labelKey;

  /// `null` = omit the parameter (server default shows everything).
  String? get wireValue => switch (this) {
    SearchAiFilter.all => null,
    SearchAiFilter.exclude => '1',
    SearchAiFilter.only => null,
  };
}

/// Aspect-ratio buckets on the official `ratio_pattern` parameter
/// (illust/manga only; confirmed against Shaft `RatioPattern`).
enum SearchRatioPattern {
  landscape('landscape', 'searchRatioLandscape'),
  portrait('portrait', 'searchRatioPortrait'),
  square('square', 'searchRatioSquare');

  const SearchRatioPattern(this.wireValue, this.labelKey);

  final String wireValue;
  final String labelKey;
}

/// Content buckets on the official `content_type` parameter (illust/manga
/// only; confirmed against Shaft `IllustContentType`). The default is the
/// server behavior and is never sent.
enum SearchContentType {
  illustAndMangaAndUgoira('illust_and_manga_and_ugoira', 'searchContentAll'),
  illustAndUgoira('illust_and_ugoira', 'searchContentIllustUgoira'),
  illust('illust', 'searchContentIllust'),
  ugoira('ugoira', 'searchContentUgoira'),
  manga('manga', 'searchContentManga');

  const SearchContentType(this.wireValue, this.labelKey);

  final String wireValue;
  final String labelKey;
}

enum SearchDuration {
  day('within_last_day', 'searchWithinDay'),
  week('within_last_week', 'searchWithinWeek'),
  month('within_last_month', 'searchWithinMonth');

  const SearchDuration(this.wireValue, this.labelKey);

  final String wireValue;
  final String labelKey;
}

/// Filters shared by Illust/Manga and Novel search. Dates are date-only so
/// timezone conversion cannot move a user's selected day across a boundary.
@immutable
class SearchFilters {
  const SearchFilters({
    this.target = SearchTarget.partialMatchForTags,
    this.sort = SearchSort.dateDesc,
    this.duration,
    this.startDate,
    this.endDate,
    this.aiFilter = SearchAiFilter.all,
    this.bookmarkMin,
    this.bookmarkMax,
    this.ratio,
    this.contentType = SearchContentType.illustAndMangaAndUgoira,
    this.widthMin,
    this.widthMax,
    this.heightMin,
    this.heightMax,
  });

  final SearchTarget target;
  final SearchSort sort;
  final SearchDuration? duration;
  final DateTime? startDate;
  final DateTime? endDate;

  /// AI-work selector; `only` is enforced client-side (no wire value).
  final SearchAiFilter aiFilter;

  /// Bookmark-count range. `bookmark_num_min/max` are Premium-only
  /// server-side — the params are still sent (free accounts are silently
  /// ignored per Shaft's verification) and the search feed re-applies the
  /// range client-side so the filter always takes effect.
  final int? bookmarkMin;
  final int? bookmarkMax;

  /// Illust-only selectors — never serialized on novel queries.
  final SearchRatioPattern? ratio;
  final SearchContentType contentType;
  final int? widthMin;
  final int? widthMax;
  final int? heightMin;
  final int? heightMax;

  /// Stable identity for feed/page-storage scopes.
  ///
  /// Search filters are part of the query contract, so a changed date range
  /// must not reuse the previous result surface's identity. Keep this key
  /// based on the same normalized wire values sent to Pixiv rather than on
  /// [Object.toString], which is not a semantic representation of filters.
  String get cacheKey => [
    target.wireValue,
    sort.wireValue,
    duration?.wireValue ?? '',
    startDate == null ? '' : _formatDate(startDate!),
    endDate == null ? '' : _formatDate(endDate!),
    aiFilter.name,
    bookmarkMin?.toString() ?? '',
    bookmarkMax?.toString() ?? '',
    ratio?.wireValue ?? '',
    contentType.wireValue,
    widthMin?.toString() ?? '',
    widthMax?.toString() ?? '',
    heightMin?.toString() ?? '',
    heightMax?.toString() ?? '',
  ].join('|');

  static const defaults = SearchFilters();

  /// Serializes the filter set into app-API query parameters.
  ///
  /// `duration` is never sent: Pixiv's honoring of `within_last_*` on the
  /// app API is unreliable, so a preset is resolved client-side into
  /// `start_date`/`end_date` (today−N .. today, local time) like every
  /// other client (PixEz/Shaft/pxview). A duration also overrides any
  /// custom date bounds: the two are mutually exclusive in the sheet UI,
  /// and this keeps the wire shape sane for stale states.
  Map<String, String> toQuery({
    required String word,
    bool includeIllustParams = false,
  }) {
    final normalized = word.trim();
    if (normalized.isEmpty) {
      throw const FormatException('search word must not be empty');
    }
    final range = _effectiveDateRange();
    final query = <String, String>{
      'word': normalized,
      'search_target': target.wireValue,
      // The novel endpoint 400s on the gendered popularity sorts — callers
      // pass a normalized sort via [novelSafe] when includeIllustParams is
      // false.
      'sort': includeIllustParams ? sort.wireValue : sort.novelSafe.wireValue,
      'filter': 'for_android',
      if (range.$1 != null) 'start_date': _formatDate(range.$1!),
      if (range.$2 != null) 'end_date': _formatDate(range.$2!),
      if (aiFilter.wireValue != null) 'search_ai_type': aiFilter.wireValue!,
      if (bookmarkMin != null) 'bookmark_num_min': '$bookmarkMin',
      if (bookmarkMax != null) 'bookmark_num_max': '$bookmarkMax',
      if (includeIllustParams) ...{
        if (ratio != null) 'ratio_pattern': ratio!.wireValue,
        if (contentType != SearchContentType.illustAndMangaAndUgoira)
          'content_type': contentType.wireValue,
        if (widthMin != null) 'width_min': '$widthMin',
        if (widthMax != null) 'width_max': '$widthMax',
        if (heightMin != null) 'height_min': '$heightMin',
        if (heightMax != null) 'height_max': '$heightMax',
      },
    };
    if (range.$1 != null && range.$2 != null && range.$1!.isAfter(range.$2!)) {
      throw const FormatException('search start date is after end date');
    }
    return query;
  }

  /// Same request shape minus `sort`: the `popular-preview` endpoints carry
  /// the popularity ordering implicitly and reject a sort parameter.
  Map<String, String> toPreviewQuery({
    required String word,
    bool includeIllustParams = false,
  }) {
    final query = toQuery(word: word, includeIllustParams: includeIllustParams)
      ..remove('sort');
    return query;
  }

  /// Resolves [duration] into an absolute range; a set duration wins over
  /// any custom bounds. Both endpoints are date-only, local time.
  (DateTime?, DateTime?) _effectiveDateRange() {
    final days = switch (duration) {
      SearchDuration.day => 1,
      SearchDuration.week => 7,
      SearchDuration.month => 30,
      null => 0,
    };
    if (days > 0) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return (today.subtract(Duration(days: days)), today);
    }
    return (startDate, endDate);
  }

  SearchFilters copyWith({
    SearchTarget? target,
    SearchSort? sort,
    Object? duration = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
    SearchAiFilter? aiFilter,
    Object? bookmarkMin = _unset,
    Object? bookmarkMax = _unset,
    Object? ratio = _unset,
    SearchContentType? contentType,
    Object? widthMin = _unset,
    Object? widthMax = _unset,
    Object? heightMin = _unset,
    Object? heightMax = _unset,
  }) {
    return SearchFilters(
      target: target ?? this.target,
      sort: sort ?? this.sort,
      duration: identical(duration, _unset)
          ? this.duration
          : duration as SearchDuration?,
      startDate: identical(startDate, _unset)
          ? this.startDate
          : startDate as DateTime?,
      endDate: identical(endDate, _unset) ? this.endDate : endDate as DateTime?,
      aiFilter: aiFilter ?? this.aiFilter,
      bookmarkMin: identical(bookmarkMin, _unset)
          ? this.bookmarkMin
          : bookmarkMin as int?,
      bookmarkMax: identical(bookmarkMax, _unset)
          ? this.bookmarkMax
          : bookmarkMax as int?,
      ratio: identical(ratio, _unset)
          ? this.ratio
          : ratio as SearchRatioPattern?,
      contentType: contentType ?? this.contentType,
      widthMin: identical(widthMin, _unset) ? this.widthMin : widthMin as int?,
      widthMax: identical(widthMax, _unset) ? this.widthMax : widthMax as int?,
      heightMin: identical(heightMin, _unset)
          ? this.heightMin
          : heightMin as int?,
      heightMax: identical(heightMax, _unset)
          ? this.heightMax
          : heightMax as int?,
    );
  }

  static const _unset = Object();

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.target == target &&
      other.sort == sort &&
      _sameDay(other.startDate, startDate) &&
      _sameDay(other.endDate, endDate) &&
      other.duration == duration &&
      other.aiFilter == aiFilter &&
      other.bookmarkMin == bookmarkMin &&
      other.bookmarkMax == bookmarkMax &&
      other.ratio == ratio &&
      other.contentType == contentType &&
      other.widthMin == widthMin &&
      other.widthMax == widthMax &&
      other.heightMin == heightMin &&
      other.heightMax == heightMax;

  @override
  int get hashCode => Object.hash(
    target,
    sort,
    duration,
    _dateHash(startDate),
    _dateHash(endDate),
    aiFilter,
    bookmarkMin,
    bookmarkMax,
    ratio,
    contentType,
    widthMin,
    widthMax,
    heightMin,
    heightMax,
  );
}

sealed class SearchQuery {
  const SearchQuery(this.keyword);

  final String keyword;

  SearchResultType get type;

  Map<String, String> toQuery();

  String get cacheKey => '$type|${keyword.trim()}';

  bool get isEmpty => keyword.trim().isEmpty;
}

@immutable
class IllustSearchQuery extends SearchQuery {
  const IllustSearchQuery({
    required String keyword,
    this.filters = const SearchFilters(),
  }) : super(keyword);

  @override
  final SearchResultType type = SearchResultType.illust;

  final SearchFilters filters;

  @override
  String get cacheKey => '${super.cacheKey}|${filters.cacheKey}';

  @override
  Map<String, String> toQuery() =>
      filters.toQuery(word: keyword, includeIllustParams: true);

  IllustSearchQuery copyWith({String? keyword, SearchFilters? filters}) =>
      IllustSearchQuery(
        keyword: keyword ?? this.keyword,
        filters: filters ?? this.filters,
      );

  @override
  bool operator ==(Object other) =>
      other is IllustSearchQuery &&
      other.keyword == keyword &&
      other.filters == filters;

  @override
  int get hashCode => Object.hash(keyword, filters);

  @override
  String toString() => 'IllustSearchQuery($keyword, $filters)';
}

@immutable
class NovelSearchQuery extends SearchQuery {
  const NovelSearchQuery({
    required String keyword,
    this.filters = const SearchFilters(),
  }) : super(keyword);

  @override
  final SearchResultType type = SearchResultType.novel;

  final SearchFilters filters;

  @override
  String get cacheKey => '${super.cacheKey}|${filters.cacheKey}';

  @override
  Map<String, String> toQuery() => filters.toQuery(word: keyword);

  NovelSearchQuery copyWith({String? keyword, SearchFilters? filters}) =>
      NovelSearchQuery(
        keyword: keyword ?? this.keyword,
        filters: filters ?? this.filters,
      );

  @override
  bool operator ==(Object other) =>
      other is NovelSearchQuery &&
      other.keyword == keyword &&
      other.filters == filters;

  @override
  int get hashCode => Object.hash(keyword, filters);

  @override
  String toString() => 'NovelSearchQuery($keyword, $filters)';
}

@immutable
class UserSearchQuery extends SearchQuery {
  const UserSearchQuery({required String keyword}) : super(keyword);

  @override
  final SearchResultType type = SearchResultType.user;

  @override
  Map<String, String> toQuery() {
    final normalized = keyword.trim();
    if (normalized.isEmpty) {
      throw const FormatException('search word must not be empty');
    }
    return {'word': normalized, 'filter': 'for_android'};
  }

  UserSearchQuery copyWith({String? keyword}) =>
      UserSearchQuery(keyword: keyword ?? this.keyword);

  @override
  bool operator ==(Object other) =>
      other is UserSearchQuery && other.keyword == keyword;

  @override
  int get hashCode => keyword.hashCode;

  @override
  String toString() => 'UserSearchQuery($keyword)';
}

String _formatDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

bool _sameDay(DateTime? left, DateTime? right) =>
    left?.year == right?.year &&
    left?.month == right?.month &&
    left?.day == right?.day;

int? _dateHash(DateTime? value) =>
    value == null ? null : Object.hash(value.year, value.month, value.day);
