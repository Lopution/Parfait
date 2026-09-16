import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/json_read.dart';

import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'novel_entity.dart';
import 'novel_webview_text.dart';

/// The API returned metadata without a body for this novel. This is distinct
/// from a valid, intentionally empty body and is shown as an explicit error.
class _NovelContentUnavailableException implements Exception {
  const _NovelContentUnavailableException(this.novelId);

  final int novelId;

  @override
  String toString() => 'NovelContentUnavailableException($novelId)';
}

class NovelPage {
  const NovelPage({required this.novels, required this.nextUrl});

  final List<NovelEntity> novels;
  final String? nextUrl;
}

class NovelSeriesPage {
  const NovelSeriesPage({
    required this.seriesId,
    required this.title,
    required this.entries,
    required this.nextUrl,
  });

  final int seriesId;
  final String? title;
  final List<NovelSeriesEntry> entries;
  final String? nextUrl;
}

/// Novel API adapter.
///
/// `/v2/novel/detail` only returns metadata: pixiv never ships `novel_text`
/// in the JSON envelope. The body lives in the `/webview/v2/novel` page's
/// embedded pixiv bootstrap object (the same source every working client
/// uses), so [fetchDetail] always merges both responses. A missing or
/// malformed webview payload is an error, never a silent empty body.
/// `/v1/novel/ranking` modes (PixEz's 9-mode list, same values Shaft uses).
/// The fixed order is part of the visible contract; API values are explicit
/// so an enum reorder cannot silently change a request.
enum NovelRankingMode {
  day('day', 'rankingDay'),
  dayMale('day_male', 'rankingDayMale'),
  dayFemale('day_female', 'rankingDayFemale'),
  week('week', 'rankingWeek'),
  weekAi('week_ai', 'rankingWeekAi'),
  weekAiR18('week_ai_r18', 'rankingWeekAiR18'),
  dayR18('day_r18', 'rankingDayR18'),
  weekR18('week_r18', 'rankingWeekR18'),
  weekR18G('week_r18g', 'rankingWeekR18G');

  const NovelRankingMode(this.apiValue, this.labelKey);

  final String apiValue;
  final String labelKey;
}

abstract interface class _NovelRepository {
  Future<NovelEntity> fetchDetail(int novelId, {CancelToken? cancelToken});

  Future<NovelPage> fetchRanking(
    NovelRankingMode mode, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateRankingCursor(NovelRankingMode mode, {required String cursor});

  Future<NovelPage> fetchUserNovels(
    int userId, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateUserNovelsCursor(int userId, {required String cursor});

  Future<NovelPage> fetchRecommended({
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateRecommendedCursor({required String cursor});

  Future<NovelSeriesPage> fetchSeries(
    int seriesId, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateSeriesCursor(int seriesId, {required String cursor});
}

class _PixivNovelRepository implements _NovelRepository {
  _PixivNovelRepository(this._client);

  final PixivHttpClient _client;

  static const _detailPath = '/v2/novel/detail';
  static const _webviewPath = '/webview/v2/novel';
  static const _userNovelsPath = '/v1/user/novels';
  static const _recommendedPath = '/v1/novel/recommended';
  static const _rankingPath = '/v1/novel/ranking';
  static const _seriesPath = '/v2/novel/series';

  @override
  Future<NovelEntity> fetchDetail(
    int novelId, {
    CancelToken? cancelToken,
  }) async {
    _validateId(novelId, 'novelId');
    final json = await _client.getJson(
      PixivClientIdentity.appApiBase.replace(
        path: _detailPath,
        queryParameters: {'novel_id': '$novelId'},
      ),
      cancelToken: cancelToken,
    );
    try {
      var novel = NovelEntity.fromDetailJson(json);
      if (!novel.visible || novel.isXRestricted) return novel;
      final payload = await _fetchWebPayload(novelId, cancelToken);
      novel = novel.withWebContent(
        payload.text,
        embeddedImages: payload.images,
        embeddedIllustThumbs: payload.illustThumbs,
        seriesPrevId: payload.seriesPrevId,
        seriesNextId: payload.seriesNextId,
      );
      if (!novel.contentAvailable) {
        throw _NovelContentUnavailableException(novel.id);
      }
      return novel;
    } on _NovelContentUnavailableException {
      rethrow;
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  /// Fetches the HTML bootstrap page that carries the novel body. The
  /// response is not JSON; [extractNovelWebPayload] decodes it.
  Future<NovelWebPayload> _fetchWebPayload(
    int novelId,
    CancelToken? cancelToken,
  ) async {
    final response = await _client.get(
      PixivClientIdentity.appApiBase.replace(
        path: _webviewPath,
        queryParameters: {'id': '$novelId'},
      ),
      cancelToken: cancelToken,
    );
    return extractNovelWebPayload(utf8.decode(response.bodyBytes));
  }

  @override
  Future<NovelPage> fetchUserNovels(
    int userId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _validateId(userId, 'userId');
    final request = _pageRequest(
      path: _userNovelsPath,
      expected: {'filter': 'for_android', 'user_id': '$userId'},
      cursor: cursor,
    );
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseNovelPage(json);
  }

  @override
  bool validateUserNovelsCursor(int userId, {required String cursor}) {
    _validateId(userId, 'userId');
    return _isValidCursor(
      path: _userNovelsPath,
      expected: {'filter': 'for_android', 'user_id': '$userId'},
      cursor: cursor,
    );
  }

  @override
  Future<NovelPage> fetchRecommended({
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(
      path: _recommendedPath,
      expected: {'filter': 'for_android'},
      cursor: cursor,
    );
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseNovelPage(json);
  }

  @override
  bool validateRecommendedCursor({required String cursor}) {
    return _isValidCursor(
      path: _recommendedPath,
      expected: {'filter': 'for_android'},
      cursor: cursor,
    );
  }

  @override
  Future<NovelPage> fetchRanking(
    NovelRankingMode mode, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(
      path: _rankingPath,
      expected: {'filter': 'for_android', 'mode': mode.apiValue},
      cursor: cursor,
    );
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseNovelPage(json);
  }

  @override
  bool validateRankingCursor(NovelRankingMode mode, {required String cursor}) {
    return _isValidCursor(
      path: _rankingPath,
      expected: {'filter': 'for_android', 'mode': mode.apiValue},
      cursor: cursor,
    );
  }

  @override
  Future<NovelSeriesPage> fetchSeries(
    int seriesId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _validateId(seriesId, 'seriesId');
    final request = _pageRequest(
      path: _seriesPath,
      expected: {'filter': 'for_android', 'series_id': '$seriesId'},
      cursor: cursor,
    );
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseSeriesPage(json, seriesId);
  }

  @override
  bool validateSeriesCursor(int seriesId, {required String cursor}) {
    _validateId(seriesId, 'seriesId');
    return _isValidCursor(
      path: _seriesPath,
      expected: {'filter': 'for_android', 'series_id': '$seriesId'},
      cursor: cursor,
    );
  }

  NextPageRequest _pageRequest({
    required String path,
    required Map<String, String> expected,
    required String? cursor,
  }) {
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(path, expected)
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      _validateCursor(request, path, expected);
      return request;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
  }

  bool _isValidCursor({
    required String path,
    required Map<String, String> expected,
    required String cursor,
  }) {
    try {
      _pageRequest(path: path, expected: expected, cursor: cursor);
      return true;
    } on ApiParseError {
      return false;
    }
  }

  void _validateCursor(
    NextPageRequest request,
    String path,
    Map<String, String> expected,
  ) {
    if (request.uri.path != path) {
      throw NextPageParseError(
        'next_url endpoint does not match $path: ${request.uri.path}',
      );
    }
    for (final entry in expected.entries) {
      if (request.query[entry.key] != entry.value) {
        throw NextPageParseError(
          'next_url ${entry.key} does not match the active novel feed',
        );
      }
    }
  }

  Uri _target(NextPageRequest request) {
    if (request.uri.hasScheme) return request.uri;
    return PixivClientIdentity.appApiBase.replace(
      path: request.uri.path,
      query: request.uri.query,
    );
  }

  NovelPage _parseNovelPage(Map<String, dynamic> json) {
    final raw = json['novels'];
    if (raw is! List) {
      throw const ApiParseError('novels list is missing or malformed');
    }
    try {
      return NovelPage(
        novels: [
          for (final item in raw)
            if (item is Map<String, dynamic>)
              NovelEntity.fromJson(item)
            else
              throw const FormatException('novels contains a non-object'),
        ],
        nextUrl: readNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  NovelSeriesPage _parseSeriesPage(
    Map<String, dynamic> json,
    int requestedSeriesId,
  ) {
    final raw = json['novels'];
    if (raw is! List) {
      throw const ApiParseError('series novels list is missing or malformed');
    }
    final detail = readMap(json['novel_series_detail']);
    final parsedSeriesId = readPositiveInt(detail['id']) ?? requestedSeriesId;
    final title = readOptionalString(detail['title']);
    try {
      return NovelSeriesPage(
        seriesId: parsedSeriesId,
        title: title,
        entries: [for (final item in raw) _parseSeriesEntry(item)],
        nextUrl: readNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  NovelSeriesEntry _parseSeriesEntry(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('series novels contains a non-object');
    }
    final id = readPositiveInt(value['id']);
    final title = readOptionalString(value['title']);
    if (id == null || title == null) {
      throw const FormatException('series novel is missing id or title');
    }
    return NovelSeriesEntry(
      id: id,
      title: title,
      viewable: value['visible'] is! bool || value['visible'] == true,
      contentOrder: readOptionalString(value['content_order']),
      viewableMessage: readOptionalString(value['viewable_message']),
    );
  }

  static void _validateId(int value, String field) {
    if (value <= 0) throw ArgumentError.value(value, field);
  }
}

final novelRepositoryProvider = Provider<_NovelRepository>((ref) {
  return _PixivNovelRepository(ref.watch(pixivHttpClientProvider));
});
