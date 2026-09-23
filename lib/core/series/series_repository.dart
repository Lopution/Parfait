import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../entity/json_read.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'series_models.dart';

/// One page of a series' works (`GET /v1/illust/series`), newest first.
class SeriesWorksPage {
  const SeriesWorksPage({
    required this.detail,
    required this.illusts,
    required this.nextUrl,
  });

  /// `illust_series_detail`; absent only on a malformed envelope.
  final IllustSeriesEntity? detail;
  final List<IllustEntity> illusts;
  final String? nextUrl;
}

/// One page of a user's series list (`GET /v1/user/illust-series`).
class UserSeriesPage {
  const UserSeriesPage({required this.series, required this.nextUrl});

  final List<IllustSeriesEntity> series;
  final String? nextUrl;
}

/// `/v1/illust-series/illust` result: where one work sits inside its series.
/// Non-series works return null [detail]/[context].
class IllustSeriesContextResult {
  const IllustSeriesContextResult({
    this.detail,
    this.context,
    this.prevIllust,
    this.nextIllust,
  });

  final IllustSeriesEntity? detail;
  final IllustSeriesContext? context;

  /// Full illust payloads for the neighbouring works; callers merge them
  /// into the shared IllustStore so the prev/next buttons can Hero-push.
  final IllustEntity? prevIllust;
  final IllustEntity? nextIllust;
}

/// Illust-series API boundary. Owns response normalization and next-page
/// validation; controllers only receive typed pages.
class PixivSeriesRepository {
  PixivSeriesRepository(this._client);

  final PixivHttpClient _client;

  static const _seriesWorksPath = '/v1/illust/series';
  static const _illustContextPath = '/v1/illust-series/illust';
  static const _userSeriesPath = '/v1/user/illust-series';

  /// Series detail plus one page of its works. The cursor is Pixiv's
  /// `last_order` (carried by `next_url`), not an offset.
  Future<SeriesWorksPage> fetchSeriesWorks(
    int seriesId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _validateId(seriesId, 'seriesId');
    final request = _pageRequest(
      path: _seriesWorksPath,
      expected: {'filter': 'for_android', 'illust_series_id': '$seriesId'},
      cursor: cursor,
    );
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseSeriesWorksPage(json);
  }

  /// Detail-page context: the series this illust belongs to plus its
  /// previous/next work. Non-series works return a result with null
  /// [IllustSeriesContextResult.context] — the API answers 404 for them,
  /// which is a normal absence signal, not a fetch failure.
  Future<IllustSeriesContextResult> fetchIllustSeriesContext(
    int illustId, {
    CancelToken? cancelToken,
  }) async {
    _validateId(illustId, 'illustId');
    final Map<String, dynamic> json;
    try {
      json = await _client.getJson(
        PixivClientIdentity.appApiBase.replace(
          path: _illustContextPath,
          queryParameters: {'illust_id': '$illustId'},
        ),
        cancelToken: cancelToken,
      );
    } on ApiHttpError catch (error) {
      if (error.statusCode == 404) {
        return const IllustSeriesContextResult();
      }
      rethrow;
    }
    return _parseContextResult(json);
  }

  /// A user's public illust series, paged via `next_url` offset.
  Future<UserSeriesPage> fetchUserSeries(
    int userId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _validateId(userId, 'userId');
    final request = _pageRequest(
      path: _userSeriesPath,
      expected: {'filter': 'for_android', 'user_id': '$userId'},
      cursor: cursor,
    );
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseUserSeriesPage(json);
  }

  bool validateSeriesCursor(int seriesId, {required String cursor}) {
    _validateId(seriesId, 'seriesId');
    return _isValidCursor(
      path: _seriesWorksPath,
      expected: {'filter': 'for_android', 'illust_series_id': '$seriesId'},
      cursor: cursor,
    );
  }

  bool validateUserSeriesCursor(int userId, {required String cursor}) {
    _validateId(userId, 'userId');
    return _isValidCursor(
      path: _userSeriesPath,
      expected: {'filter': 'for_android', 'user_id': '$userId'},
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
          'next_url ${entry.key} does not match the active series feed',
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

  SeriesWorksPage _parseSeriesWorksPage(Map<String, dynamic> json) {
    final rawIllusts = json['illusts'];
    if (rawIllusts is! List) {
      throw const ApiParseError('illust series works envelope is malformed');
    }
    try {
      final illusts = <IllustEntity>[
        for (final item in rawIllusts)
          if (item is Map<String, dynamic>)
            IllustEntity.fromJson(item)
          else
            throw const FormatException('series illusts has a non-object'),
      ];
      final detailJson = json['illust_series_detail'];
      IllustSeriesEntity? detail;
      if (detailJson is Map<String, dynamic>) {
        final latest = json['illust_series_latest_illust'];
        final first = json['illust_series_first_illust'];
        detail = IllustSeriesEntity.fromJson(
          detailJson,
          latestContentId: latest is Map<String, dynamic>
              ? readPositiveInt(latest['id'])
              : null,
          firstContentId: first is Map<String, dynamic>
              ? readPositiveInt(first['id'])
              : null,
        );
      }
      return SeriesWorksPage(
        detail: detail,
        illusts: illusts,
        nextUrl: readNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  IllustSeriesContextResult _parseContextResult(Map<String, dynamic> json) {
    try {
      final detailJson = json['illust_series_detail'];
      final detail = detailJson is Map<String, dynamic>
          ? IllustSeriesEntity.fromJson(detailJson)
          : null;
      final contextJson = json['illust_series_context'];
      if (contextJson is! Map<String, dynamic>) {
        return IllustSeriesContextResult(detail: detail);
      }
      final prev = _tryParseIllust(contextJson['prev']);
      final next = _tryParseIllust(contextJson['next']);
      final seriesId = detail?.id ?? readPositiveInt(contextJson['series_id']);
      if (seriesId == null) {
        return IllustSeriesContextResult(detail: detail);
      }
      return IllustSeriesContextResult(
        detail: detail,
        context: IllustSeriesContext(
          seriesId: seriesId,
          contentOrder: readPositiveInt(contextJson['content_order']),
          prevIllustId: prev?.id,
          nextIllustId: next?.id,
        ),
        prevIllust: prev,
        nextIllust: next,
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  /// A malformed neighbour must not lose the whole context section — the
  /// direction just renders without that button.
  IllustEntity? _tryParseIllust(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    try {
      return IllustEntity.fromJson(value);
    } on FormatException {
      return null;
    }
  }

  UserSeriesPage _parseUserSeriesPage(Map<String, dynamic> json) {
    final raw = json['illust_series_details'];
    if (raw is! List) {
      throw const ApiParseError(
        'illust_series_details list is missing or malformed',
      );
    }
    try {
      return UserSeriesPage(
        series: [
          for (final item in raw)
            if (item is Map<String, dynamic>)
              IllustSeriesEntity.fromJson(item)
            else
              throw const FormatException(
                'illust_series_details has a non-object',
              ),
        ],
        nextUrl: readNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  static void _validateId(int value, String field) {
    if (value <= 0) throw ArgumentError.value(value, field);
  }
}

final seriesRepositoryProvider = Provider<PixivSeriesRepository>((ref) {
  return PixivSeriesRepository(ref.watch(pixivHttpClientProvider));
});
