import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../entity/comment_entity.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'comment_models.dart';
import '../entity/json_read.dart';

/// JSON boundary for Pixiv comments and replies.
abstract interface class CommentRepository {
  Future<CommentPage> fetchComments(
    int workId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  });

  Future<CommentPage> fetchReplies(
    int rootCommentId, {
    required int workId,
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateCursor(CommentFeedQuery query, {required String cursor});

  Future<CommentEntity> addComment(
    CommentAddRequest request, {
    CancelToken? cancelToken,
  });

  Future<void> deleteComment(
    int commentId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    CancelToken? cancelToken,
  });
}

/// Pixiv app-api implementation for the beta56 comment contract.
class _PixivCommentRepository implements CommentRepository {
  _PixivCommentRepository(this._client);

  static const _commentsPaths = {
    CommentWorkKind.illust: '/v3/illust/comments',
    CommentWorkKind.novel: '/v3/novel/comments',
  };
  static const _repliesPaths = {
    CommentWorkKind.illust: '/v2/illust/comment/replies',
    CommentWorkKind.novel: '/v2/novel/comment/replies',
  };
  static const _addPaths = {
    CommentWorkKind.illust: '/v1/illust/comment/add',
    CommentWorkKind.novel: '/v1/novel/comment/add',
  };
  static const _deletePaths = {
    CommentWorkKind.illust: '/v1/illust/comment/delete',
    CommentWorkKind.novel: '/v1/novel/comment/delete',
  };

  static String _workIdField(CommentWorkKind kind) => '${kind.name}_id';

  final PixivHttpClient _client;

  @override
  Future<CommentPage> fetchComments(
    int workId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _requirePositive(workId, 'workId');
    return _fetch(
      CommentFeedQuery.root(workId: workId, kind: kind),
      cursor: cursor,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<CommentPage> fetchReplies(
    int rootCommentId, {
    required int workId,
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    _requirePositive(rootCommentId, 'rootCommentId');
    _requirePositive(workId, 'workId');
    return _fetch(
      CommentFeedQuery.replies(
        workId: workId,
        kind: kind,
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
      _workIdField(request.kind): '${request.workId}',
      if (request.normalizedText != null) 'comment': request.normalizedText!,
      if (request.stampId != null) 'stamp_id': '${request.stampId}',
      if (request.parentCommentId != null)
        'parent_comment_id': '${request.parentCommentId}',
    };
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: _addPaths[request.kind]!),
      body: body,
      cancelToken: cancelToken,
      // C2: an explicit auth rejection refreshes the credential and replays
      // this mutation at most once; other outcomes never replay.
      allowAuthReplay: true,
    );
    final json = _successObject(response);
    final rawComment = json['comment'];
    if (rawComment is! Map<String, dynamic>) {
      throw const ApiParseError('comment add response is missing comment');
    }
    try {
      return CommentEntity.fromJson(
        rawComment,
        workId: request.workId,
        kind: request.kind,
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
  Future<void> deleteComment(
    int commentId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    CancelToken? cancelToken,
  }) async {
    _requirePositive(commentId, 'commentId');
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: _deletePaths[kind]!),
      body: {'comment_id': '$commentId'},
      cancelToken: cancelToken,
      allowAuthReplay: true,
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
            workId: query.workId,
            kind: query.kind,
            rootCommentId: query.rootCommentId,
          ),
        );
      }
      return CommentPage(
        comments: comments,
        nextUrl: requireNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  NextPageRequest _pageRequest(
    CommentFeedQuery query, {
    required String? cursor,
  }) {
    final path = query.isReplies
        ? _repliesPaths[query.kind]!
        : _commentsPaths[query.kind]!;
    final expected = query.isReplies
        ? {'comment_id': '${query.rootCommentId}'}
        : {_workIdField(query.kind): '${query.workId}'};
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

  static Map<String, dynamic> _successObject(
    http.Response response, {
    bool allowEmpty = false,
  }) {
    final body = utf8.decode(response.bodyBytes);
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
      throw ApiHttpError(response.statusCode, decoded['message']?.toString());
    }
    return decoded;
  }

  static void _requirePositive(int value, String field) {
    if (value <= 0) throw FormatException('$field must be positive');
  }
}

final commentRepositoryProvider = Provider<CommentRepository>((ref) {
  return _PixivCommentRepository(ref.watch(pixivHttpClientProvider));
});
