import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../network/api_date.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';

/// The fixed beta56 order is part of the visible contract. API values are
/// explicit so a future enum reorder cannot silently change a request.
enum RankingMode {
  day('day', 'rankingDay'),
  dayR18('day_r18', 'rankingDayR18'),
  dayMale('day_male', 'rankingDayMale'),
  dayMaleR18('day_male_r18', 'rankingDayMaleR18'),
  dayFemale('day_female', 'rankingDayFemale'),
  dayFemaleR18('day_female_r18', 'rankingDayFemaleR18'),
  week('week', 'rankingWeek'),
  weekR18('week_r18', 'rankingWeekR18'),
  weekOriginal('week_original', 'rankingWeekOriginal'),
  weekRookie('week_rookie', 'rankingWeekRookie'),
  month('month', 'rankingMonth');

  const RankingMode(this.apiValue, this.labelKey);

  final String apiValue;
  final String labelKey;

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
    try {
      final json = await _client.getJson(target, cancelToken: cancelToken);
      final page = IllustEntity.parsePage(json);
      return RankingIllustPage(illusts: page.illusts, nextUrl: page.nextUrl);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
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
