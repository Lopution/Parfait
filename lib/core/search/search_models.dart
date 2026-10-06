/// Typed search selectors and wire values shared by search repositories/pages.
/// This library owns enum-to-wire mappings; query UI state belongs to the
/// search controllers. See `frontend/type-safety.md`.
library;

import 'package:flutter/foundation.dart';

import '../network/api_date.dart';

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
/// request because callers can only construct this enum. `text` and
/// `keyword` are novel-search targets only — illust filters normalize them
/// to [partialMatchForTags] at decode and never offer them.
enum SearchTarget {
  partialMatchForTags('partial_match_for_tags', 'searchPartialTags'),
  exactMatchForTags('exact_match_for_tags', 'searchExactTags'),
  titleAndCaption('title_and_caption', 'searchTitleCaption'),
  text('text', 'searchTargetText'),
  keyword('keyword', 'searchTargetKeyword');

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
  /// serializing.
  SearchSort get novelSafe =>
      isPopular && this != popularDesc ? popularDesc : this;
}

/// AI-work selector. Pixiv's `search_ai_type` is binary (0=all, 1=exclude);
/// "only AI" has no wire value and is applied client-side on
/// `illust_ai_type == 2` / `novel_ai_type == 2` in the search feed's page
/// filter.
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
/// (illust/manga only).
enum SearchRatioPattern {
  landscape('landscape', 'searchRatioLandscape'),
  portrait('portrait', 'searchRatioPortrait'),
  square('square', 'searchRatioSquare');

  const SearchRatioPattern(this.wireValue, this.labelKey);

  final String wireValue;
  final String labelKey;
}

/// Content buckets on the official `content_type` parameter (illust/manga
/// only). The default is the
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

/// Filters for one artwork search type. Illustration and novel searches own
/// one set each — shared dims live on this base, type-specific dims on the
/// subclasses, so a type only ever displays and sends its own dimensions.
/// Dates are date-only so timezone conversion cannot move a user's selected
/// day across a boundary.
@immutable
sealed class SearchFilters {
  const SearchFilters({
    this.target = SearchTarget.partialMatchForTags,
    this.sort = SearchSort.dateDesc,
    this.duration,
    this.startDate,
    this.endDate,
    this.aiFilter = SearchAiFilter.all,
    this.bookmarkMin,
    this.bookmarkMax,
  });

  /// Search-range selector. The valid set depends on the type — see
  /// [targetOptions]; foreign values are clamped at decode/serialize.
  final SearchTarget target;
  final SearchSort sort;
  final SearchDuration? duration;
  final DateTime? startDate;
  final DateTime? endDate;

  /// AI-work selector; `only` is enforced client-side (no wire value).
  final SearchAiFilter aiFilter;

  /// Bookmark-count range. `bookmark_num_min/max` are Premium-only
  /// server-side — the params are still sent (free accounts are silently
  /// ignored) and the search feed re-applies the
  /// range client-side so the filter always takes effect.
  final int? bookmarkMin;
  final int? bookmarkMax;

  /// The result type this filter set belongs to.
  SearchResultType get type;

  /// The search targets this type accepts — the sheet offers exactly these.
  List<SearchTarget> get targetOptions;

  /// The sort orders this type's endpoint accepts.
  List<SearchSort> get sortOptions;

  /// [target] clamped into [targetOptions] for serialization.
  SearchTarget get normalizedTarget => clampTarget(target, targetOptions);

  /// Clamps [value] into [options], falling back to the first option —
  /// every type-specific decode (settings JSON, route params) runs the raw
  /// value through this so a foreign target can never reach display code.
  static SearchTarget clampTarget(
    SearchTarget value,
    List<SearchTarget> options,
  ) => options.contains(value) ? value : options.first;

  /// Stable identity for feed/page-storage scopes.
  ///
  /// Search filters are part of the query contract, so a changed date range
  /// must not reuse the previous result surface's identity. Keep this key
  /// based on the same normalized wire values sent to Pixiv rather than on
  /// [Object.toString], which is not a semantic representation of filters.
  String get cacheKey => [
    normalizedTarget.wireValue,
    normalizedSort.wireValue,
    duration?.wireValue ?? '',
    startDate == null ? '' : formatApiDate(startDate!),
    endDate == null ? '' : formatApiDate(endDate!),
    aiFilter.name,
    bookmarkMin?.toString() ?? '',
    bookmarkMax?.toString() ?? '',
    ...ownCacheKeyParts,
  ].join('|');

  /// The sort after the type's normalization (novel drops gendered sorts).
  SearchSort get normalizedSort => sort;

  /// Type-specific cache key tail.
  List<String> get ownCacheKeyParts;

  /// Persisted shared fields stored inside AppSettings. Enums serialize by
  /// their stable wire values so an enum reorder or rename cannot silently
  /// change a user's persisted selection; dates stay date-only local.
  Map<String, Object?> sharedJson() => {
    'target': normalizedTarget.wireValue,
    'sort': normalizedSort.wireValue,
    if (duration != null) 'duration': duration!.wireValue,
    if (startDate != null) 'startDate': formatApiDate(startDate!),
    if (endDate != null) 'endDate': formatApiDate(endDate!),
    'aiFilter': aiFilter.name,
    if (bookmarkMin != null) 'bookmarkMin': bookmarkMin,
    if (bookmarkMax != null) 'bookmarkMax': bookmarkMax,
  };

  Map<String, Object?> toJson();

  /// Serializes the filter set into app-API query parameters.
  ///
  /// `duration` is never sent: Pixiv's honoring of `within_last_*` on the
  /// app API is unreliable, so a preset is resolved client-side into
  /// `start_date`/`end_date` (today−N .. today, local time). A duration
  /// also overrides any
  /// custom date bounds: the two are mutually exclusive in the sheet UI,
  /// and this keeps the wire shape sane for stale states.
  Map<String, String> toQuery({required String word}) {
    final normalized = word.trim();
    if (normalized.isEmpty) {
      throw const FormatException('search word must not be empty');
    }
    final range = effectiveDateRange();
    final query = <String, String>{
      'word': normalized,
      'search_target': normalizedTarget.wireValue,
      'sort': normalizedSort.wireValue,
      'filter': 'for_android',
      if (range.$1 != null) 'start_date': formatApiDate(range.$1!),
      if (range.$2 != null) 'end_date': formatApiDate(range.$2!),
      if (aiFilter.wireValue != null) 'search_ai_type': aiFilter.wireValue!,
      ..._boundQuery('bookmark_num', bookmarkMin, bookmarkMax),
    };
    if (range.$1 != null && range.$2 != null && range.$1!.isAfter(range.$2!)) {
      throw const FormatException('search start date is after end date');
    }
    return query;
  }

  /// Same request shape minus `sort`: the `popular-preview` endpoints carry
  /// the popularity ordering implicitly and reject a sort parameter.
  Map<String, String> toPreviewQuery({required String word}) {
    final query = toQuery(word: word)..remove('sort');
    return query;
  }

  /// Resolves [duration] into an absolute range; a set duration wins over
  /// any custom bounds. Both endpoints are date-only, local time.
  (DateTime?, DateTime?) effectiveDateRange() {
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

  /// Whether [min] is above [max]. The filter sheet shows such a pair as an
  /// error and will not apply it; the wire rejects it.
  static bool isReversed(int? min, int? max) =>
      min != null && max != null && min > max;

  /// A bound pair read from storage or a link: negative values are dropped
  /// and a reversed pair is put in order. Earlier sheets saved reversed
  /// pairs and swapped them on the wire, so ordering keeps what those users
  /// searched for — and the sheet then shows the pair it sends.
  static (int?, int?) decodeBounds(int? min, int? max) {
    final low = min != null && min >= 0 ? min : null;
    final high = max != null && max >= 0 ? max : null;
    return isReversed(low, high) ? (high, low) : (low, high);
  }

  static Map<String, String> _boundQuery(String name, int? min, int? max) {
    if (isReversed(min, max)) {
      throw FormatException('search ${name}_min is above ${name}_max');
    }
    return {
      if (min != null) '${name}_min': '$min',
      if (max != null) '${name}_max': '$max',
    };
  }

  /// copyWith over the shared dims — the filter sheet edits them without
  /// knowing the concrete subclass.
  SearchFilters copyShared({
    SearchTarget? target,
    SearchSort? sort,
    Object? duration = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
    SearchAiFilter? aiFilter,
    Object? bookmarkMin = _unset,
    Object? bookmarkMax = _unset,
  });

  bool _sharedEquals(SearchFilters other) =>
      other.target == target &&
      other.sort == sort &&
      _sameDay(other.startDate, startDate) &&
      _sameDay(other.endDate, endDate) &&
      other.duration == duration &&
      other.aiFilter == aiFilter &&
      other.bookmarkMin == bookmarkMin &&
      other.bookmarkMax == bookmarkMax;

  int get _sharedHash => Object.hash(
    target,
    sort,
    duration,
    _dateHash(startDate),
    _dateHash(endDate),
    aiFilter,
    bookmarkMin,
    bookmarkMax,
  );
}

/// Sentinel for "argument not passed" in filter copy methods — `null` is a
/// meaningful value (clear the bound), so a plain nullable parameter cannot
/// express "leave unchanged".
const Object _unset = Object();

typedef _SharedFieldValues = ({
  SearchTarget target,
  SearchSort sort,
  SearchDuration? duration,
  DateTime? startDate,
  DateTime? endDate,
  SearchAiFilter aiFilter,
  int? bookmarkMin,
  int? bookmarkMax,
});

/// Per-field validation shared by both subclasses: one damaged field falls
/// back to its default without discarding the other selections. The target
/// is not clamped here — each subclass clamps it into its own options.
_SharedFieldValues _sharedFieldsFromJson(Map<dynamic, dynamic> json) {
  DateTime? dateOf(String key) {
    final raw = json[key];
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  T? wireOf<T>(String key, Iterable<T> values, String Function(T) wire) {
    final raw = json[key];
    if (raw is! String) return null;
    return values.where((value) => wire(value) == raw).firstOrNull;
  }

  final (bookmarkMin, bookmarkMax) = _boundsFromJson(
    json,
    'bookmarkMin',
    'bookmarkMax',
  );
  return (
    target:
        wireOf('target', SearchTarget.values, (v) => v.wireValue) ??
        SearchTarget.partialMatchForTags,
    sort:
        wireOf('sort', SearchSort.values, (v) => v.wireValue) ??
        SearchSort.dateDesc,
    duration: wireOf('duration', SearchDuration.values, (v) => v.wireValue),
    startDate: dateOf('startDate'),
    endDate: dateOf('endDate'),
    aiFilter:
        SearchAiFilter.values
            .where((value) => value.name == json['aiFilter'])
            .firstOrNull ??
        SearchAiFilter.all,
    bookmarkMin: bookmarkMin,
    bookmarkMax: bookmarkMax,
  );
}

/// A stored bound pair through [SearchFilters.decodeBounds]; a value that
/// is not an int counts as unset.
(int?, int?) _boundsFromJson(
  Map<dynamic, dynamic> json,
  String minKey,
  String maxKey,
) {
  int? intOf(String key) => switch (json[key]) {
    final int value => value,
    _ => null,
  };
  return SearchFilters.decodeBounds(intOf(minKey), intOf(maxKey));
}

/// Illustration/manga search filters — the full shared set plus ratio,
/// content type and pixel bounds, which the novel endpoint does not have.
final class IllustSearchFilters extends SearchFilters {
  const IllustSearchFilters({
    super.target,
    super.sort,
    super.duration,
    super.startDate,
    super.endDate,
    super.aiFilter,
    super.bookmarkMin,
    super.bookmarkMax,
    this.ratio,
    this.contentType = SearchContentType.illustAndMangaAndUgoira,
    this.widthMin,
    this.widthMax,
    this.heightMin,
    this.heightMax,
  });

  static const defaults = IllustSearchFilters();

  /// Illust-only selectors — never serialized on novel queries.
  final SearchRatioPattern? ratio;
  final SearchContentType contentType;
  final int? widthMin;
  final int? widthMax;
  final int? heightMin;
  final int? heightMax;

  @override
  SearchResultType get type => SearchResultType.illust;

  @override
  List<SearchTarget> get targetOptions => const [
    SearchTarget.partialMatchForTags,
    SearchTarget.exactMatchForTags,
    SearchTarget.titleAndCaption,
  ];

  @override
  List<SearchSort> get sortOptions => SearchSort.values;

  @override
  List<String> get ownCacheKeyParts => [
    ratio?.wireValue ?? '',
    contentType.wireValue,
    widthMin?.toString() ?? '',
    widthMax?.toString() ?? '',
    heightMin?.toString() ?? '',
    heightMax?.toString() ?? '',
  ];

  @override
  Map<String, Object?> toJson() => {
    ...sharedJson(),
    if (ratio != null) 'ratio': ratio!.wireValue,
    'contentType': contentType.wireValue,
    if (widthMin != null) 'widthMin': widthMin,
    if (widthMax != null) 'widthMax': widthMax,
    if (heightMin != null) 'heightMin': heightMin,
    if (heightMax != null) 'heightMax': heightMax,
  };

  /// Per-field validation: one damaged field falls back to its default
  /// without discarding the other selections. A non-map value yields the
  /// full default set. Novel-only targets (`text`/`keyword`) never appear
  /// here — the shared decode feeds into [targetOptions] clamping.
  factory IllustSearchFilters.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final shared = _sharedFieldsFromJson(json);
    final (widthMin, widthMax) = _boundsFromJson(json, 'widthMin', 'widthMax');
    final (heightMin, heightMax) = _boundsFromJson(
      json,
      'heightMin',
      'heightMax',
    );
    return IllustSearchFilters(
      target: SearchFilters.clampTarget(shared.target, defaults.targetOptions),
      sort: shared.sort,
      duration: shared.duration,
      startDate: shared.startDate,
      endDate: shared.endDate,
      aiFilter: shared.aiFilter,
      bookmarkMin: shared.bookmarkMin,
      bookmarkMax: shared.bookmarkMax,
      ratio: switch (json['ratio']) {
        final String wire =>
          SearchRatioPattern.values
              .where((value) => value.wireValue == wire)
              .firstOrNull,
        _ => null,
      },
      contentType: switch (json['contentType']) {
        final String wire =>
          SearchContentType.values
                  .where((value) => value.wireValue == wire)
                  .firstOrNull ??
              defaults.contentType,
        _ => defaults.contentType,
      },
      widthMin: widthMin,
      widthMax: widthMax,
      heightMin: heightMin,
      heightMax: heightMax,
    );
  }

  @override
  Map<String, String> toQuery({required String word}) {
    final query = super.toQuery(word: word);
    return {
      ...query,
      if (ratio != null) 'ratio_pattern': ratio!.wireValue,
      if (contentType != SearchContentType.illustAndMangaAndUgoira)
        'content_type': contentType.wireValue,
      ...SearchFilters._boundQuery('width', widthMin, widthMax),
      ...SearchFilters._boundQuery('height', heightMin, heightMax),
    };
  }

  @override
  SearchFilters copyShared({
    SearchTarget? target,
    SearchSort? sort,
    Object? duration = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
    SearchAiFilter? aiFilter,
    Object? bookmarkMin = _unset,
    Object? bookmarkMax = _unset,
  }) => copyWith(
    target: target,
    sort: sort,
    duration: duration,
    startDate: startDate,
    endDate: endDate,
    aiFilter: aiFilter,
    bookmarkMin: bookmarkMin,
    bookmarkMax: bookmarkMax,
  );

  IllustSearchFilters copyWith({
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
    return IllustSearchFilters(
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

  @override
  bool operator ==(Object other) =>
      other is IllustSearchFilters &&
      other._sharedEquals(this) &&
      other.ratio == ratio &&
      other.contentType == contentType &&
      other.widthMin == widthMin &&
      other.widthMax == widthMax &&
      other.heightMin == heightMin &&
      other.heightMax == heightMax;

  @override
  int get hashCode => Object.hash(
    _sharedHash,
    ratio,
    contentType,
    widthMin,
    widthMax,
    heightMin,
    heightMax,
  );
}

/// Novel search filters — the shared set plus `text_length_*` and
/// `is_original_only` (illust dims are absent by construction).
final class NovelSearchFilters extends SearchFilters {
  const NovelSearchFilters({
    super.target,
    super.sort,
    super.duration,
    super.startDate,
    super.endDate,
    super.aiFilter,
    super.bookmarkMin,
    super.bookmarkMax,
    this.textLengthMin,
    this.textLengthMax,
    this.originalOnly = false,
  });

  static const defaults = NovelSearchFilters();

  /// Text-length bounds map to `text_length_min`/`text_length_max`
  /// (novel-only; verified on the iOS app API in Shaft's SearchConfig).
  final int? textLengthMin;
  final int? textLengthMax;

  /// `is_original_only` (novel-only). False omits the parameter.
  final bool originalOnly;

  @override
  SearchResultType get type => SearchResultType.novel;

  @override
  List<SearchTarget> get targetOptions => const [
    SearchTarget.partialMatchForTags,
    SearchTarget.exactMatchForTags,
    SearchTarget.text,
    SearchTarget.keyword,
  ];

  @override
  List<SearchSort> get sortOptions => const [
    SearchSort.dateDesc,
    SearchSort.dateAsc,
    SearchSort.popularDesc,
  ];

  @override
  SearchSort get normalizedSort => sort.novelSafe;

  @override
  List<String> get ownCacheKeyParts => [
    textLengthMin?.toString() ?? '',
    textLengthMax?.toString() ?? '',
    originalOnly ? '1' : '',
  ];

  @override
  Map<String, Object?> toJson() => {
    ...sharedJson(),
    if (textLengthMin != null) 'textLengthMin': textLengthMin,
    if (textLengthMax != null) 'textLengthMax': textLengthMax,
    if (originalOnly) 'originalOnly': true,
  };

  /// Per-field validation matching [IllustSearchFilters.fromJson]. The
  /// shared dims decode identically — an illust filter blob read through
  /// this factory keeps the shared fields and drops illust-only ones, which
  /// is exactly the upgrade path for a missing `novelSearchFilters` key.
  factory NovelSearchFilters.fromJson(Object? json) {
    if (json is! Map) return defaults;
    final shared = _sharedFieldsFromJson(json);
    final (textLengthMin, textLengthMax) = _boundsFromJson(
      json,
      'textLengthMin',
      'textLengthMax',
    );
    return NovelSearchFilters(
      target: SearchFilters.clampTarget(shared.target, defaults.targetOptions),
      sort: shared.sort.novelSafe,
      duration: shared.duration,
      startDate: shared.startDate,
      endDate: shared.endDate,
      aiFilter: shared.aiFilter,
      bookmarkMin: shared.bookmarkMin,
      bookmarkMax: shared.bookmarkMax,
      textLengthMin: textLengthMin,
      textLengthMax: textLengthMax,
      originalOnly: json['originalOnly'] == true,
    );
  }

  @override
  Map<String, String> toQuery({required String word}) {
    final query = super.toQuery(word: word);
    return {
      ...query,
      ...SearchFilters._boundQuery('text_length', textLengthMin, textLengthMax),
      if (originalOnly) 'is_original_only': 'true',
    };
  }

  @override
  SearchFilters copyShared({
    SearchTarget? target,
    SearchSort? sort,
    Object? duration = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
    SearchAiFilter? aiFilter,
    Object? bookmarkMin = _unset,
    Object? bookmarkMax = _unset,
  }) => copyWith(
    target: target,
    sort: sort,
    duration: duration,
    startDate: startDate,
    endDate: endDate,
    aiFilter: aiFilter,
    bookmarkMin: bookmarkMin,
    bookmarkMax: bookmarkMax,
  );

  NovelSearchFilters copyWith({
    SearchTarget? target,
    SearchSort? sort,
    Object? duration = _unset,
    Object? startDate = _unset,
    Object? endDate = _unset,
    SearchAiFilter? aiFilter,
    Object? bookmarkMin = _unset,
    Object? bookmarkMax = _unset,
    Object? textLengthMin = _unset,
    Object? textLengthMax = _unset,
    bool? originalOnly,
  }) {
    return NovelSearchFilters(
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
      textLengthMin: identical(textLengthMin, _unset)
          ? this.textLengthMin
          : textLengthMin as int?,
      textLengthMax: identical(textLengthMax, _unset)
          ? this.textLengthMax
          : textLengthMax as int?,
      originalOnly: originalOnly ?? this.originalOnly,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NovelSearchFilters &&
      other._sharedEquals(this) &&
      other.textLengthMin == textLengthMin &&
      other.textLengthMax == textLengthMax &&
      other.originalOnly == originalOnly;

  @override
  int get hashCode =>
      Object.hash(_sharedHash, textLengthMin, textLengthMax, originalOnly);
}

sealed class SearchQuery {
  const SearchQuery(this.keyword);

  final String keyword;

  SearchResultType get type;

  Map<String, String> toQuery();

  String get cacheKey => '$type|${keyword.trim()}';

  bool get isEmpty => keyword.trim().isEmpty;

  /// The filter set this query searches with — `null` for user queries,
  /// which have no filters.
  SearchFilters? get filtersOrNull;
}

/// Builds the typed query for [type]. Artwork types get that type's own
/// filter set (its defaults when the matching argument is null) — a query
/// never carries another type's dimensions.
SearchQuery searchQueryForType(
  SearchResultType type, {
  required String keyword,
  IllustSearchFilters? illustFilters,
  NovelSearchFilters? novelFilters,
}) => switch (type) {
  SearchResultType.illust => IllustSearchQuery(
    keyword: keyword,
    filters: illustFilters ?? IllustSearchFilters.defaults,
  ),
  SearchResultType.novel => NovelSearchQuery(
    keyword: keyword,
    filters: novelFilters ?? NovelSearchFilters.defaults,
  ),
  SearchResultType.user => UserSearchQuery(keyword: keyword),
};

@immutable
class IllustSearchQuery extends SearchQuery {
  const IllustSearchQuery({
    required String keyword,
    this.filters = IllustSearchFilters.defaults,
  }) : super(keyword);

  @override
  final SearchResultType type = SearchResultType.illust;

  final IllustSearchFilters filters;

  @override
  SearchFilters get filtersOrNull => filters;

  @override
  String get cacheKey => '${super.cacheKey}|${filters.cacheKey}';

  @override
  Map<String, String> toQuery() => filters.toQuery(word: keyword);

  IllustSearchQuery copyWith({String? keyword, IllustSearchFilters? filters}) =>
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
    this.filters = NovelSearchFilters.defaults,
  }) : super(keyword);

  @override
  final SearchResultType type = SearchResultType.novel;

  final NovelSearchFilters filters;

  @override
  SearchFilters get filtersOrNull => filters;

  @override
  String get cacheKey => '${super.cacheKey}|${filters.cacheKey}';

  @override
  Map<String, String> toQuery() => filters.toQuery(word: keyword);

  NovelSearchQuery copyWith({String? keyword, NovelSearchFilters? filters}) =>
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
  SearchFilters? get filtersOrNull => null;

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

bool _sameDay(DateTime? left, DateTime? right) =>
    left?.year == right?.year &&
    left?.month == right?.month &&
    left?.day == right?.day;

int? _dateHash(DateTime? value) =>
    value == null ? null : Object.hash(value.year, value.month, value.day);
