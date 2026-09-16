import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../entity/json_read.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'bookmark_models.dart';

/// Bookmark add/delete/detail/tag-list against the Pixiv app API.
///
/// Endpoints (stable app-api contract, verified live during device
/// acceptance):
/// - POST /v2/illust/bookmark/add   body: illust_id, restrict, tags[]
/// - POST /v1/illust/bookmark/delete body: illust_id
/// - POST /v2/novel/bookmark/add    body: novel_id, restrict, tags[]
/// - POST /v1/novel/bookmark/delete body: novel_id
/// - GET  /v2/{illust,novel}/bookmark/detail
/// - GET  /v1/user/bookmark-tags/{illust,novel}
///
/// `tags[]` is sent as a single space-joined field value (PixEz wire form;
/// Shaft repeats the field — both encodings are accepted, and our form body
/// is a `Map<String, String>`).
class BookmarkRepository {
  BookmarkRepository(this._client);

  final PixivHttpClient _client;

  Future<void> addIllust(
    int id,
    BookmarkRestrict restrict, {
    List<String>? tags,
    CancelToken? cancelToken,
  }) => _add(
    id,
    'illust_id',
    '/v2/illust/bookmark/add',
    restrict,
    tags,
    cancelToken,
  );

  Future<void> deleteIllust(int id, {CancelToken? cancelToken}) =>
      _delete(id, 'illust_id', '/v1/illust/bookmark/delete', cancelToken);

  Future<void> addNovel(
    int id,
    BookmarkRestrict restrict, {
    List<String>? tags,
    CancelToken? cancelToken,
  }) => _add(
    id,
    'novel_id',
    '/v2/novel/bookmark/add',
    restrict,
    tags,
    cancelToken,
  );

  Future<void> deleteNovel(int id, {CancelToken? cancelToken}) =>
      _delete(id, 'novel_id', '/v1/novel/bookmark/delete', cancelToken);

  /// Confirmed bookmark state incl. tags, for the edit-sheet prefill.
  Future<BookmarkDetail> fetchDetail(
    BookmarkKey key, {
    CancelToken? cancelToken,
  }) async {
    final (path, idField) = switch (key.type) {
      BookmarkEntityType.illust => ('/v2/illust/bookmark/detail', 'illust_id'),
      BookmarkEntityType.novel => ('/v2/novel/bookmark/detail', 'novel_id'),
    };
    final json = await _client.getJson(
      PixivClientIdentity.appApiBase.replace(
        path: path,
        queryParameters: {idField: '${key.id}'},
      ),
      cancelToken: cancelToken,
    );
    return _parseDetail(json);
  }

  /// The user's own bookmark tag collection, paged via `next_url`.
  Future<UserBookmarkTagPage> fetchUserTags(
    int userId, {
    required BookmarkEntityType entityType,
    required BookmarkRestrict restrict,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final path = switch (entityType) {
      BookmarkEntityType.illust => '/v1/user/bookmark-tags/illust',
      BookmarkEntityType.novel => '/v1/user/bookmark-tags/novel',
    };
    final query = {
      'user_id': '$userId',
      'restrict': bookmarkRestrictWire(restrict),
    };
    final request = _pageRequest(path: path, query: query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseTagPage(json);
  }

  bool validateUserTagsCursor(
    int userId, {
    required BookmarkEntityType entityType,
    required BookmarkRestrict restrict,
    required String cursor,
  }) {
    final path = switch (entityType) {
      BookmarkEntityType.illust => '/v1/user/bookmark-tags/illust',
      BookmarkEntityType.novel => '/v1/user/bookmark-tags/novel',
    };
    try {
      _pageRequest(
        path: path,
        query: {
          'user_id': '$userId',
          'restrict': bookmarkRestrictWire(restrict),
        },
        cursor: cursor,
      );
      return true;
    } on ApiParseError {
      return false;
    }
  }

  Future<void> _add(
    int id,
    String idField,
    String path,
    BookmarkRestrict restrict,
    List<String>? tags,
    CancelToken? cancelToken,
  ) async {
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: path),
      body: {
        idField: '$id',
        'restrict': bookmarkRestrictWire(restrict),
        if (tags != null && tags.isNotEmpty) 'tags[]': tags.join(' '),
      },
      cancelToken: cancelToken,
      // C2: an explicit auth rejection (401 / 400 invalid_grant) refreshes
      // the credential and replays this operation exactly once; timeouts
      // and unknown outcomes never replay.
      allowAuthReplay: true,
    );
    _ensureSuccess(response);
  }

  Future<void> _delete(
    int id,
    String idField,
    String path,
    CancelToken? cancelToken,
  ) async {
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: path),
      body: {idField: '$id'},
      cancelToken: cancelToken,
      allowAuthReplay: true,
    );
    _ensureSuccess(response);
  }

  NextPageRequest _pageRequest({
    required String path,
    required Map<String, String> query,
    required String? cursor,
  }) {
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(path, query)
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      if (request.uri.path != path) {
        throw NextPageParseError(
          'next_url endpoint does not match $path: ${request.uri.path}',
        );
      }
      for (final entry in query.entries) {
        if (request.query[entry.key] != entry.value) {
          throw NextPageParseError(
            'next_url ${entry.key} does not match the active tag list',
          );
        }
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

  BookmarkDetail _parseDetail(Map<String, dynamic> json) {
    final detail = readMap(json['bookmark_detail']);
    final restrict = switch (readOptionalString(detail['restrict'])) {
      'private' => BookmarkRestrict.private,
      'public' => BookmarkRestrict.public,
      _ => null,
    };
    final rawTags = detail['tags'];
    return BookmarkDetail(
      isBookmarked: detail['is_bookmarked'] == true,
      restrict: restrict,
      tags: [
        if (rawTags is List)
          for (final item in rawTags)
            if (readMap(item) case final tag when tag.isNotEmpty)
              BookmarkTagFacet(
                name: readOptionalString(tag['name']) ?? '',
                isRegistered: tag['is_registered'] == true,
              ),
      ]..removeWhere((tag) => tag.name.isEmpty),
    );
  }

  UserBookmarkTagPage _parseTagPage(Map<String, dynamic> json) {
    final raw = json['bookmark_tags'];
    if (raw is! List) {
      throw const ApiParseError('bookmark_tags is missing or malformed');
    }
    return UserBookmarkTagPage(
      tags: [
        for (final item in raw)
          if (readMap(item) case final tag when tag.isNotEmpty)
            UserBookmarkTag(
              name: readOptionalString(tag['name']) ?? '',
              count: readNonNegativeIntOrZero(tag['count']),
            ),
      ]..removeWhere((tag) => tag.name.isEmpty),
      nextUrl: readNextUrl(json['next_url']),
    );
  }

  /// The API answers 200 with `{"message": ..., "is_success": false}` for
  /// logical failures; those must surface as errors, not silent success.
  void _ensureSuccess(http.Response response) {
    final statusCode = response.statusCode;
    if (statusCode < 200 || statusCode >= 300) {
      throw ApiHttpError(statusCode);
    }
    final body = utf8.decode(response.bodyBytes);
    if (body.isEmpty) return;
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
    if (decoded is Map<String, dynamic> && decoded['is_success'] == false) {
      throw ApiHttpError(statusCode, decoded['message']?.toString());
    }
  }
}

final bookmarkRepositoryProvider = Provider<BookmarkRepository>((ref) {
  return BookmarkRepository(ref.watch(pixivHttpClientProvider));
});
