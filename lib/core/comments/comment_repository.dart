import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/comment_entity.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'comment_models.dart';

/// JSON boundary for Pixiv comments and replies.
abstract interface class CommentRepository {
  Future<CommentPage> fetchComments(
    int illustId, {
    String? cursor,
    CancelToken? cancelToken,
  });

  Future<CommentPage> fetchReplies(
    int rootCommentId, {
    required int illustId,
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateCursor(CommentFeedQuery query, {required String cursor});

  Future<CommentEntity> addComment(
    CommentAddRequest request, {
    CancelToken? cancelToken,
  });

  Future<void> deleteComment(int commentId, {CancelToken? cancelToken});
}

/// Pixiv app-api implementation for the beta56 comment contract.
class PixivCommentRepository implements CommentRepository {
  PixivCommentRepository(this._client);

  static const _commentsPath = '/v3/illust/comments';
  static const _repliesPath = '/v2/illust/comment/replies';
  static const _addPath = '/v1/illust/comment/add';
  static const _deletePath = '/v1/illust/comment/delete';

  final PixivHttpClient _client;

  @override
  Future<CommentPage> fetchComments(
    int illustId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _requirePositive(illustId, 'illustId');
    return _fetch(
      CommentFeedQuery.root(illustId: illustId),
      cursor: cursor,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<CommentPage> fetchReplies(
    int rootCommentId, {
    required int illustId,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _requirePositive(rootCommentId, 'rootCommentId');
    _requirePositive(illustId, 'illustId');
    return _fetch(
      CommentFeedQuery.replies(
        illustId: illustId,
        rootCommentId: rootCommentId,
      ),
      cursor: cursor,
      cancelToken: cancelToken,
    );
  }

  @override
  bool validateCursor(CommentFeedQuery query, {required String cursor}) {
    try {
      _pageRequest(query, cursor: cursor);
      return true;
    } on ApiParseError {
      return false;
    }
  }

  @override
  Future<CommentEntity> addComment(
    CommentAddRequest request, {
    CancelToken? cancelToken,
  }) async {
    request.validate();
    final body = <String, String>{
      'illust_id': '${request.illustId}',
      if (request.normalizedText != null) 'comment': request.normalizedText!,
      if (request.stampId != null) 'stamp_id': '${request.stampId}',
      if (request.parentCommentId != null)
        'parent_comment_id': '${request.parentCommentId}',
    };
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: _addPath),
      body: body,
      cancelToken: cancelToken,
      allowAuthReplay: false,
    );
    final json = _successObject(response);
    final rawComment = json['comment'];
    if (rawComment is! Map<String, dynamic>) {
      throw const ApiParseError('comment add response is missing comment');
    }
    try {
      return CommentEntity.fromJson(
        rawComment,
        illustId: request.illustId,
        rootCommentId: request.rootCommentId,
      ).copyWith(
        parentCommentId: request.parentCommentId,
        rootCommentId: request.rootCommentId,
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  @override
  Future<void> deleteComment(int commentId, {CancelToken? cancelToken}) async {
    _requirePositive(commentId, 'commentId');
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: _deletePath),
      body: {'comment_id': '$commentId'},
      cancelToken: cancelToken,
      allowAuthReplay: false,
    );
    _successObject(response, allowEmpty: true);
  }

  Future<CommentPage> _fetch(
    CommentFeedQuery query, {
    required String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    try {
      final rawComments = json['comments'];
      if (rawComments is! List) {
        throw const FormatException('comments list is missing');
      }
      final comments = <CommentEntity>[];
      for (final item in rawComments) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('comments contains a non-object');
        }
        comments.add(
          CommentEntity.fromJson(
            item,
            illustId: query.illustId,
            rootCommentId: query.rootCommentId,
          ),
        );
      }
      return CommentPage(
        comments: comments,
        nextUrl: _nextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  NextPageRequest _pageRequest(
    CommentFeedQuery query, {
    required String? cursor,
  }) {
    final path = query.isReplies ? _repliesPath : _commentsPath;
    final expected = query.isReplies
        ? {'comment_id': '${query.rootCommentId}'}
        : {'illust_id': '${query.illustId}'};
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(path, expected)
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      if (request.uri.path != path) {
        throw NextPageParseError(
          'next_url endpoint does not match $path: ${request.uri.path}',
        );
      }
      for (final entry in expected.entries) {
        if (request.query[entry.key] != entry.value) {
          throw NextPageParseError(
            'next_url ${entry.key} does not match ${query.cacheKey}',
          );
        }
      }
      return request;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
  }

  Uri _target(NextPageRequest request) => PixivClientIdentity.appApiBase
      .replace(path: request.uri.path, queryParameters: request.query);

  static String? _nextUrl(Object? value) {
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    if (value is String) return null;
    throw const FormatException('next_url must be a string or null');
  }

  static Map<String, dynamic> _successObject(
    dynamic response, {
    bool allowEmpty = false,
  }) {
    final body = utf8.decode(response.bodyBytes as List<int>);
    if (body.isEmpty && allowEmpty) return const {};
    if (body.isEmpty) throw const ApiParseError('empty mutation response');
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ApiParseError('mutation response is not an object');
    }
    if (decoded['is_success'] == false) {
      throw ApiHttpError(
        response.statusCode as int,
        decoded['message']?.toString(),
      );
    }
    return decoded;
  }

  static void _requirePositive(int value, String field) {
    if (value <= 0) throw FormatException('$field must be positive');
  }
}

final commentRepositoryProvider = Provider<CommentRepository>((ref) {
  return PixivCommentRepository(ref.watch(pixivHttpClientProvider));
});
