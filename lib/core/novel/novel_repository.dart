import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'novel_entity.dart';

/// The API returned metadata without a body for this novel. This is distinct
/// from a valid, intentionally empty body and is shown as an explicit error.
class NovelContentUnavailableException implements Exception {
  const NovelContentUnavailableException(this.novelId);

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

/// JSON-only Novel API adapter.
///
/// `/webview/v2/novel` is intentionally absent here: it is the legacy HTML
/// route and cannot be used as a silent fallback when the JSON body is absent.
abstract interface class NovelRepository {
  Future<NovelEntity> fetchDetail(int novelId, {CancelToken? cancelToken});

  Future<NovelPage> fetchUserNovels(
    int userId, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateUserNovelsCursor(int userId, {required String cursor});

  Future<NovelSeriesPage> fetchSeries(
    int seriesId, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateSeriesCursor(int seriesId, {required String cursor});
}

class PixivNovelRepository implements NovelRepository {
  PixivNovelRepository(this._client);

  final PixivHttpClient _client;

  static const _detailPath = '/v2/novel/detail';
  static const _userNovelsPath = '/v1/user/novels';
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
      final novel = NovelEntity.fromDetailJson(json);
      if (!novel.visible || novel.isXRestricted) return novel;
      if (!novel.contentAvailable) {
        throw NovelContentUnavailableException(novel.id);
      }
      return novel;
    } on NovelContentUnavailableException {
      rethrow;
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
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
        nextUrl: _nextUrl(json['next_url']),
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
    final detail = _map(json['novel_series_detail']);
    final parsedSeriesId = _positiveInt(detail['id']) ?? requestedSeriesId;
    final title = _optionalString(detail['title']);
    try {
      return NovelSeriesPage(
        seriesId: parsedSeriesId,
        title: title,
        entries: [for (final item in raw) _parseSeriesEntry(item)],
        nextUrl: _nextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  NovelSeriesEntry _parseSeriesEntry(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('series novels contains a non-object');
    }
    final id = _positiveInt(value['id']);
    final title = _optionalString(value['title']);
    if (id == null || title == null) {
      throw const FormatException('series novel is missing id or title');
    }
    return NovelSeriesEntry(
      id: id,
      title: title,
      viewable: value['visible'] is! bool || value['visible'] == true,
      contentOrder: _optionalString(value['content_order']),
      viewableMessage: _optionalString(value['viewable_message']),
    );
  }

  static void _validateId(int value, String field) {
    if (value <= 0) throw ArgumentError.value(value, field);
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse('$value');
    return parsed == null || parsed <= 0 ? null : parsed;
  }

  static String? _optionalString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const <String, dynamic>{};

  static String? _nextUrl(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

final novelRepositoryProvider = Provider<NovelRepository>((ref) {
  return PixivNovelRepository(ref.watch(pixivHttpClientProvider));
});
