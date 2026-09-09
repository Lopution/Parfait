import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
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

class RankingIllustPage {
  const RankingIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

/// Fetches and normalizes one ranking mode without mutating shared state.
class RankingRepository {
  RankingRepository(this._client);

  final PixivHttpClient _client;

  Future<RankingIllustPage> fetchPage(
    RankingMode mode,
    String? cursor, {
    CancelToken? cancelToken,
  }) async {
    final NextPageRequest request;
    try {
      request = cursor == null
          ? NextPageParser.firstPage('/v1/illust/ranking', {
              'filter': 'for_android',
              'mode': mode.apiValue,
            })
          : NextPageParser.parse(cursor)!;
      validateModeCursor(request, mode);
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

  static void validateModeCursor(NextPageRequest request, RankingMode mode) {
    if (request.uri.path != '/v1/illust/ranking') {
      throw NextPageParseError('cursor endpoint is not ranking');
    }
    final cursorMode = request.query['mode'];
    if (cursorMode != mode.apiValue) {
      throw NextPageParseError(
        'cursor mode ${cursorMode ?? '<missing>'} does not match ${mode.apiValue}',
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
