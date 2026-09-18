import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/json_read.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'watchlist_models.dart';

/// `/v1/watchlist/{manga,novel}` boundary. The watchlist always tracks a
/// *series* — manga entries are illust series, novel entries are novel
/// series (PixEz `api_client.dart` contract):
/// - GET  /v1/watchlist/{manga,novel}          → {series:[...], next_url}
/// - POST /v1/watchlist/{manga,novel}/add      form: series_id
/// - POST /v1/watchlist/{manga,novel}/delete   form: series_id
class PixivWatchlistRepository {
  PixivWatchlistRepository(this._client);

  final PixivHttpClient _client;

  static String _path(WatchlistType type) => '/v1/watchlist/${type.apiValue}';

  /// One page of the watchlist, newest changes first. `next_url` pagination
  /// is validated against the list path before reuse.
  Future<WatchlistSeriesPage> fetchWatchlist(
    WatchlistType type, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(type: type, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parsePage(json, type);
  }

  Future<void> add(WatchlistKey key, {CancelToken? cancelToken}) =>
      _mutate(key, 'add', cancelToken);

  Future<void> delete(WatchlistKey key, {CancelToken? cancelToken}) =>
      _mutate(key, 'delete', cancelToken);

  bool validateCursor(WatchlistType type, {required String cursor}) {
    try {
      _pageRequest(type: type, cursor: cursor);
      return true;
    } on ApiParseError {
      return false;
    }
  }

  Future<void> _mutate(
    WatchlistKey key,
    String verb,
    CancelToken? cancelToken,
  ) async {
    _validateId(key.seriesId, 'seriesId');
    await _client.post(
      PixivClientIdentity.appApiBase.replace(
        path: '/v1/watchlist/${key.type.apiValue}/$verb',
      ),
      body: {'series_id': '${key.seriesId}'},
      cancelToken: cancelToken,
      allowAuthReplay: true,
    );
  }

  NextPageRequest _pageRequest({
    required WatchlistType type,
    required String? cursor,
  }) {
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(_path(type), const {})
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      if (request.uri.path != _path(type)) {
        throw NextPageParseError(
          'next_url endpoint does not match ${_path(type)}: '
          '${request.uri.path}',
        );
      }
      return request;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
  }

  Uri _target(NextPageRequest request) {
    if (request.uri.hasScheme) return request.uri;
    return PixivClientIdentity.appApiBase.replace(
      path: request.uri.path,
      query: request.uri.query,
    );
  }

  WatchlistSeriesPage _parsePage(
    Map<String, dynamic> json,
    WatchlistType type,
  ) {
    final raw = json['series'];
    if (raw is! List) {
      throw const ApiParseError('watchlist series list is missing');
    }
    try {
      return WatchlistSeriesPage(
        entries: [
          for (final item in raw)
            if (item is Map<String, dynamic>)
              _parseEntry(item, type)
            else
              throw const FormatException('watchlist series has a non-object'),
        ],
        nextUrl: readNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  WatchlistSeriesEntry _parseEntry(
    Map<String, dynamic> json,
    WatchlistType type,
  ) {
    final id = readPositiveInt(json['id']);
    final title = readOptionalString(json['title']);
    final user = json['user'];
    if (id == null || title == null || user is! Map<String, dynamic>) {
      throw const FormatException(
        'watchlist series entry is missing required fields',
      );
    }
    final userId = readPositiveInt(user['id']);
    if (userId == null) {
      throw const FormatException('watchlist series user id is invalid');
    }
    final avatar = user['profile_image_urls'];
    return WatchlistSeriesEntry(
      id: id,
      type: type,
      title: title,
      userId: userId,
      userName: readOptionalString(user['name']) ?? '',
      userAvatarUrl: avatar is Map<String, dynamic>
          ? readFirstString(avatar, const ['medium'])
          : null,
      latestContentId: readPositiveInt(json['latest_content_id']),
      lastPublishedContentDatetime: readOptionalString(
        json['last_published_content_datetime'],
      ),
      publishedContentCount: readPositiveInt(json['published_content_count']),
      coverUrl: readOptionalString(json['url']),
      maskText: readOptionalString(json['mask_text']),
    );
  }

  static void _validateId(int value, String field) {
    if (value <= 0) throw ArgumentError.value(value, field);
  }
}

final watchlistRepositoryProvider = Provider<PixivWatchlistRepository>((ref) {
  return PixivWatchlistRepository(ref.watch(pixivHttpClientProvider));
});
