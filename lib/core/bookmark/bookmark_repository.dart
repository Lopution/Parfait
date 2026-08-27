import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'bookmark_models.dart';

/// Bookmark add/delete against the Pixiv app API.
///
/// Endpoints (stable app-api contract, verified live during device
/// acceptance):
/// - POST /v2/illust/bookmark/add   body: illust_id, restrict
/// - POST /v1/illust/bookmark/delete body: illust_id
class BookmarkRepository {
  BookmarkRepository(this._client);

  final PixivHttpClient _client;

  Future<void> addIllust(
    int id,
    BookmarkRestrict restrict, {
    CancelToken? cancelToken,
  }) async {
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: '/v2/illust/bookmark/add'),
      body: {'illust_id': '$id', 'restrict': bookmarkRestrictWire(restrict)},
      cancelToken: cancelToken,
      allowAuthReplay: false,
    );
    _ensureSuccess(response);
  }

  Future<void> deleteIllust(int id, {CancelToken? cancelToken}) async {
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(
        path: '/v1/illust/bookmark/delete',
      ),
      body: {'illust_id': '$id'},
      cancelToken: cancelToken,
      allowAuthReplay: false,
    );
    _ensureSuccess(response);
  }

  /// The API answers 200 with `{"message": ..., "is_success": false}` for
  /// logical failures; those must surface as errors, not silent success.
  void _ensureSuccess(dynamic response) {
    final statusCode = response.statusCode as int;
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
