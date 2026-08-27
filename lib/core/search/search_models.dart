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
  popularDesc('popular_desc', 'searchPopularDesc');

  const SearchSort(this.wireValue, this.labelKey);

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
  });

  final SearchTarget target;
  final SearchSort sort;
  final SearchDuration? duration;
  final DateTime? startDate;
  final DateTime? endDate;

  static const defaults = SearchFilters();

  Map<String, String> toQuery({required String word}) {
    final normalized = word.trim();
    if (normalized.isEmpty) {
      throw const FormatException('search word must not be empty');
    }
    final query = <String, String>{
      'word': normalized,
      'search_target': target.wireValue,
      'sort': sort.wireValue,
      'filter': 'for_android',
      if (duration != null) 'duration': duration!.wireValue,
      if (startDate != null) 'start_date': _formatDate(startDate!),
      if (endDate != null) 'end_date': _formatDate(endDate!),
    };
    if (startDate != null && endDate != null && startDate!.isAfter(endDate!)) {
      throw const FormatException('search start date is after end date');
    }
    return query;
  }

  SearchFilters copyWith({
    SearchTarget? target,
    SearchSort? sort,
    Object? duration = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
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
      other.duration == duration;

  @override
  int get hashCode => Object.hash(
    target,
    sort,
    duration,
    _dateHash(startDate),
    _dateHash(endDate),
  );
}

sealed class SearchQuery {
  const SearchQuery(this.keyword);

  final String keyword;

  SearchResultType get type;

  Map<String, String> toQuery();

  String get cacheKey => '$type|${keyword.trim()}|$this';

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
  Map<String, String> toQuery() => filters.toQuery(word: keyword);

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
