import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../network/api_date.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../ranking/ranking_category.dart';
import '../settings/arrangement.dart';

/// `/v1/illust/ranking` modes (21, probed 2026-10-11). The tab order is
/// [defaultArrangement] or the user's; API values are explicit so an enum
/// reorder cannot silently change a request.
enum RankingMode implements RankingCategory {
  day('day', 'rankingDay'),
  week('week', 'rankingWeek'),
  month('month', 'rankingMonth'),
  weekRookie('week_rookie', 'rankingWeekRookie'),
  weekOriginal('week_original', 'rankingWeekOriginal'),
  dayAi('day_ai', 'rankingAi', isAi: true),
  dayMale('day_male', 'rankingDayMale'),
  dayFemale('day_female', 'rankingDayFemale'),
  dayR18('day_r18', 'rankingDayR18', rating: RankingRating.r18),
  weekR18('week_r18', 'rankingWeekR18', rating: RankingRating.r18),
  dayR18Ai('day_r18_ai', 'rankingAiR18', rating: RankingRating.r18, isAi: true),
  dayMaleR18('day_male_r18', 'rankingDayMaleR18', rating: RankingRating.r18),
  dayFemaleR18(
    'day_female_r18',
    'rankingDayFemaleR18',
    rating: RankingRating.r18,
  ),
  weekR18G('week_r18g', 'rankingWeekR18G', rating: RankingRating.r18g),
  dayManga('day_manga', 'rankingDayManga'),
  weekManga('week_manga', 'rankingWeekManga'),
  monthManga('month_manga', 'rankingMonthManga'),
  weekRookieManga('week_rookie_manga', 'rankingWeekRookieManga'),
  dayR18Manga('day_r18_manga', 'rankingDayR18Manga', rating: RankingRating.r18),
  weekR18Manga(
    'week_r18_manga',
    'rankingWeekR18Manga',
    rating: RankingRating.r18,
  ),
  weekR18GManga(
    'week_r18g_manga',
    'rankingWeekR18GManga',
    rating: RankingRating.r18g,
  );

  const RankingMode(
    this.apiValue,
    this.labelKey, {
    this.rating = RankingRating.allAges,
    this.isAi = false,
  });

  @override
  final String apiValue;
  @override
  final String labelKey;
  @override
  final RankingRating rating;
  @override
  final bool isAi;

  /// pixiv web's ranking order, all ages before R-18; R-18G and manga are
  /// offered but hidden.
  static const defaultArrangement = Arrangement<RankingMode>(
    shown: [
      day,
      week,
      month,
      weekRookie,
      weekOriginal,
      dayAi,
      dayMale,
      dayFemale,
      dayR18,
      weekR18,
      dayR18Ai,
      dayMaleR18,
      dayFemaleR18,
    ],
    hidden: [
      weekR18G,
      dayManga,
      weekManga,
      monthManga,
      weekRookieManga,
      dayR18Manga,
      weekR18Manga,
      weekR18GManga,
    ],
  );

  static RankingMode? fromApiValue(String value) {
    for (final mode in values) {
      if (mode.apiValue == value) return mode;
    }
    return null;
  }
}

/// The first day pixiv has a ranking for (illust and novel alike).
final rankingFirstDate = DateTime(2007, 9, 13);

/// The newest past ranking: yesterday in Japan, where rankings are
/// published. Today's ranking is the "latest" one (no date).
DateTime rankingLastDate({DateTime? now}) {
  final japan = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 9));
  return DateTime(japan.year, japan.month, japan.day - 1);
}

/// [date] when it is a pickable past ranking day, otherwise null (the
/// latest ranking).
DateTime? rankingDateOrLatest(DateTime? date, {DateTime? now}) {
  if (date == null ||
      date.isBefore(rankingFirstDate) ||
      date.isAfter(rankingLastDate(now: now))) {
    return null;
  }
  return date;
}

class RankingIllustPage {
  const RankingIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

/// Fetches and normalizes one ranking mode without mutating shared state.
class RankingRepository {
  RankingRepository(this._client);

  final PixivHttpClient _client;

  /// [date] picks a past ranking; null is the latest.
  Future<RankingIllustPage> fetchPage(
    RankingMode mode,
    String? cursor, {
    DateTime? date,
    CancelToken? cancelToken,
  }) async {
    final NextPageRequest request;
    try {
      request = cursor == null
          ? NextPageParser.firstPage('/v1/illust/ranking', {
              'filter': 'for_android',
              'mode': mode.apiValue,
              if (date != null) 'date': formatApiDate(date),
            })
          : NextPageParser.parse(cursor)!;
      validateModeCursor(request, mode, date: date);
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }

    final target = request.uri.hasScheme
        ? request.uri
        : PixivClientIdentity.appApiBase.replace(
            path: request.uri.path,
            query: request.uri.query,
          );
    final page = await _client.getParsed(
      target,
      IllustEntity.parsePage,
      cancelToken: cancelToken,
    );
    return RankingIllustPage(illusts: page.illusts, nextUrl: page.nextUrl);
  }

  static void validateModeCursor(
    NextPageRequest request,
    RankingMode mode, {
    DateTime? date,
  }) {
    if (request.uri.path != '/v1/illust/ranking') {
      throw NextPageParseError('cursor endpoint is not ranking');
    }
    final cursorMode = request.query['mode'];
    if (cursorMode != mode.apiValue) {
      throw NextPageParseError(
        'cursor mode ${cursorMode ?? '<missing>'} does not match ${mode.apiValue}',
      );
    }
    // A cursor from another day's ranking (or the latest one) must not
    // continue this list.
    final cursorDate = request.query['date'];
    final expectedDate = date == null ? null : formatApiDate(date);
    if (cursorDate != expectedDate) {
      throw NextPageParseError(
        'cursor date ${cursorDate ?? '<latest>'} does not match '
        '${expectedDate ?? '<latest>'}',
      );
    }
    final filter = request.query['filter'];
    if (filter != null && filter != 'for_android') {
      throw NextPageParseError('unsupported ranking filter: $filter');
    }
    final offset = request.query['offset'];
    if (offset != null && !RegExp(r'^\d+$').hasMatch(offset)) {
      throw NextPageParseError('ranking offset must be numeric');
    }
  }
}

final rankingRepositoryProvider = Provider<RankingRepository>((ref) {
  return RankingRepository(ref.watch(pixivHttpClientProvider));
});
