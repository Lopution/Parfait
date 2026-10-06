import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/search/search_models.dart';

void main() {
  test('typed search filters serialize only allowlisted values', () {
    final filters = IllustSearchFilters(
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
      final query = IllustSearchFilters(
        duration: duration,
      ).toQuery(word: 'cat');
      // `within_last_*` is never sent — Pixiv's honoring of it on the app
      // API is unreliable, so every comparable client resolves presets
      // client-side.
      expect(query.containsKey('duration'), isFalse);
      expect(query['start_date'], fmt(today.subtract(Duration(days: days))));
      expect(query['end_date'], fmt(today));
    }
  });

  test('a duration preset wins over stale custom dates', () {
    final query = IllustSearchFilters(
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
    final query = const IllustSearchFilters(
      sort: SearchSort.popularDesc,
    ).toPreviewQuery(word: 'cat');
    expect(query.containsKey('sort'), isFalse);
    expect(query['word'], 'cat');
    expect(query['filter'], 'for_android');
  });

  test('illust-only filters serialize on illust, never on novel', () {
    const illustFilters = IllustSearchFilters(
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
      filters: illustFilters,
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
      filters: NovelSearchFilters(
        aiFilter: SearchAiFilter.exclude,
        bookmarkMin: 100,
        bookmarkMax: 5000,
      ),
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

  test('novel-only filters serialize on novel, never on illust', () {
    final novel = const NovelSearchQuery(
      keyword: 'cat',
      filters: NovelSearchFilters(
        target: SearchTarget.text,
        textLengthMin: 1000,
        textLengthMax: 30000,
        originalOnly: true,
      ),
    ).toQuery();
    expect(novel['search_target'], 'text');
    expect(novel['text_length_min'], '1000');
    expect(novel['text_length_max'], '30000');
    expect(novel['is_original_only'], 'true');

    // `keyword` is the other novel-only target.
    final byKeyword = const NovelSearchQuery(
      keyword: 'cat',
      filters: NovelSearchFilters(target: SearchTarget.keyword),
    ).toQuery();
    expect(byKeyword['search_target'], 'keyword');

    // The illust query has no novel dims by construction — clamped decode
    // keeps `text`/`keyword` from ever reaching the illust wire.
    final clamped = IllustSearchFilters.fromJson({'target': 'text'});
    expect(clamped.target, SearchTarget.partialMatchForTags);
    final illust = IllustSearchQuery(
      keyword: 'cat',
      filters: clamped,
    ).toQuery();
    expect(illust['search_target'], 'partial_match_for_tags');
  });

  test('gendered sorts normalize to popular_desc on the novel wire', () {
    for (final sort in [
      SearchSort.popularMaleDesc,
      SearchSort.popularFemaleDesc,
    ]) {
      final query = NovelSearchQuery(
        keyword: 'cat',
        filters: NovelSearchFilters(sort: sort),
      ).toQuery();
      // The novel endpoint 400s on male/female sorts — never emit them.
      expect(query['sort'], 'popular_desc');
    }
    final illust = const IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(sort: SearchSort.popularMaleDesc),
    ).toQuery();
    expect(illust['sort'], 'popular_male_desc');
  });

  test('ai-only has no wire value; exclude serializes search_ai_type=1', () {
    final only = const IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(aiFilter: SearchAiFilter.only),
    ).toQuery();
    expect(only.containsKey('search_ai_type'), isFalse);

    final all = const IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(aiFilter: SearchAiFilter.all),
    ).toQuery();
    expect(all.containsKey('search_ai_type'), isFalse);
  });

  test('search cache keys include the active filter set', () {
    const base = IllustSearchQuery(keyword: 'cat');
    final dated = IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(
        sort: SearchSort.dateAsc,
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 27),
      ),
    );
    final duration = IllustSearchQuery(
      keyword: 'cat',
      filters: IllustSearchFilters(duration: SearchDuration.week),
    );

    expect(dated.cacheKey, isNot(base.cacheKey));
    expect(duration.cacheKey, isNot(base.cacheKey));
    expect(dated.cacheKey, contains('date_asc'));
    expect(dated.cacheKey, contains('2026-08-01'));
    expect(dated.cacheKey, contains('2026-08-27'));
  });

  test('cache keys include each type\'s own dimensions', () {
    const illust = IllustSearchFilters();
    expect(
      illust.copyWith(ratio: SearchRatioPattern.square).cacheKey,
      isNot(illust.cacheKey),
    );
    expect(illust.copyWith(widthMin: 800).cacheKey, isNot(illust.cacheKey));

    const novel = NovelSearchFilters();
    expect(novel.copyWith(textLengthMin: 1000).cacheKey, isNot(novel.cacheKey));
    expect(novel.copyWith(originalOnly: true).cacheKey, isNot(novel.cacheKey));
  });

  test('a novel preview query keeps the novel dimensions', () {
    final query = const NovelSearchFilters(
      sort: SearchSort.popularDesc,
      textLengthMin: 1000,
      originalOnly: true,
    ).toPreviewQuery(word: 'cat');
    expect(query.containsKey('sort'), isFalse);
    expect(query['text_length_min'], '1000');
    expect(query['is_original_only'], 'true');
  });

  test('an empty word is rejected for every type', () {
    for (final query in [
      const IllustSearchQuery(keyword: '  '),
      const NovelSearchQuery(keyword: ''),
      const UserSearchQuery(keyword: ' '),
    ]) {
      expect(query.isEmpty, isTrue);
      expect(query.toQuery, throwsFormatException, reason: '${query.type}');
    }
  });

  test('a reversed bound pair is rejected on the wire', () {
    // The sheet will not apply one, and decoding orders stored ones, so a
    // reversed pair here is a bug to surface — never a value to fix up.
    final reversed = <SearchFilters>[
      const IllustSearchFilters(bookmarkMin: 10, bookmarkMax: 5),
      const IllustSearchFilters(widthMin: 10, widthMax: 5),
      const IllustSearchFilters(heightMin: 10, heightMax: 5),
      const NovelSearchFilters(textLengthMin: 10, textLengthMax: 5),
    ];
    for (final (index, filters) in reversed.indexed) {
      expect(
        () => filters.toQuery(word: 'cat'),
        throwsFormatException,
        reason: 'pair $index',
      );
    }
    // An equal pair asks for one exact value.
    final exact = const IllustSearchFilters(
      bookmarkMin: 5,
      bookmarkMax: 5,
    ).toQuery(word: 'cat');
    expect((exact['bookmark_num_min'], exact['bookmark_num_max']), ('5', '5'));
  });

  test('stored bounds decode in order and without negatives', () {
    // Earlier sheets saved reversed pairs and swapped them on the wire.
    final illust = IllustSearchFilters.fromJson({
      'bookmarkMin': 500,
      'bookmarkMax': 100,
      'widthMin': -1,
      'widthMax': 800,
      'heightMin': 600,
      'heightMax': 'tall',
    });
    expect((illust.bookmarkMin, illust.bookmarkMax), (100, 500));
    expect((illust.widthMin, illust.widthMax), (null, 800));
    expect((illust.heightMin, illust.heightMax), (600, null));
    expect(illust.toQuery(word: 'cat')['bookmark_num_min'], '100');

    final novel = NovelSearchFilters.fromJson({
      'textLengthMin': 9000,
      'textLengthMax': 100,
      'bookmarkMax': -3,
    });
    expect((novel.textLengthMin, novel.textLengthMax), (100, 9000));
    expect(novel.bookmarkMax, isNull);
  });

  test('copyShared edits shared dimensions and keeps the type\'s own', () {
    const illust = IllustSearchFilters(
      ratio: SearchRatioPattern.portrait,
      widthMin: 800,
    );
    final edited = illust.copyShared(sort: SearchSort.dateAsc, bookmarkMin: 50);
    expect(
      edited,
      const IllustSearchFilters(
        sort: SearchSort.dateAsc,
        bookmarkMin: 50,
        ratio: SearchRatioPattern.portrait,
        widthMin: 800,
      ),
    );

    const novel = NovelSearchFilters(textLengthMax: 5000, originalOnly: true);
    expect(
      novel.copyShared(aiFilter: SearchAiFilter.exclude),
      const NovelSearchFilters(
        aiFilter: SearchAiFilter.exclude,
        textLengthMax: 5000,
        originalOnly: true,
      ),
    );
    // Null is a value: it clears a bound instead of leaving it unchanged.
    expect(
      const NovelSearchFilters(
        bookmarkMin: 10,
      ).copyShared(bookmarkMin: null).bookmarkMin,
      isNull,
    );
  });

  test('filters compare dates by day', () {
    final morning = IllustSearchFilters(startDate: DateTime(2026, 8, 1, 9));
    final evening = IllustSearchFilters(startDate: DateTime(2026, 8, 1, 21));
    expect(morning, evening);
    expect(morning.hashCode, evening.hashCode);
    expect(
      morning,
      isNot(IllustSearchFilters(startDate: DateTime(2026, 8, 2))),
    );
  });

  test('a query for a type carries only that type\'s filter set', () {
    const illustFilters = IllustSearchFilters(widthMin: 800);
    const novelFilters = NovelSearchFilters(textLengthMin: 1000);
    SearchQuery queryFor(SearchResultType type) => searchQueryForType(
      type,
      keyword: 'cat',
      illustFilters: illustFilters,
      novelFilters: novelFilters,
    );

    expect(queryFor(SearchResultType.illust).filtersOrNull, illustFilters);
    expect(queryFor(SearchResultType.novel).filtersOrNull, novelFilters);
    expect(queryFor(SearchResultType.user).filtersOrNull, isNull);
    // A missing set falls back to that type's defaults.
    expect(
      searchQueryForType(SearchResultType.novel, keyword: 'cat').filtersOrNull,
      NovelSearchFilters.defaults,
    );
  });
}
