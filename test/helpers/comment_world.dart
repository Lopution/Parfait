import 'dart:async';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/comments/comment_models.dart';
import 'package:parfait/core/comments/comment_repository.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/user/user_entity.dart';

import 'fake_account.dart';

/// The comments' signed-in account: user 10 owns the sample comments.
StubAccountStore commentsAccountStore() =>
    StubAccountStore(const Account(id: 'account', userId: 10, name: 'tester'));

CommentEntity sampleComment(
  int id, {
  int workId = 1,
  CommentWorkKind kind = CommentWorkKind.illust,
  int userId = 10,
  int? parentCommentId,
  int? rootCommentId,
  int replyCount = 0,
  String? content,
}) => CommentEntity(
  id: id,
  workId: workId,
  kind: kind,
  parentCommentId: parentCommentId,
  rootCommentId: rootCommentId ?? id,
  user: UserEntity(id: userId, name: 'user $userId', account: 'user_$userId'),
  content: content ?? 'comment $id',
  createdAt: DateTime.utc(2026, 8, 27),
  hasReplies: replyCount > 0,
  replyCount: replyCount,
);

class FakeCommentRepository implements CommentRepository {
  final requests = <CommentFeedQuery>[];
  int deleteCalls = 0;
  Completer<CommentEntity>? addCompleter;
  List<CommentEntity>? rootComments;
  List<CommentEntity>? replies;
  Object? addError;

  @override
  Future<CommentPage> fetchComments(
    int workId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final query = CommentFeedQuery.root(workId: workId, kind: kind);
    requests.add(query);
    return CommentPage(
      comments:
          rootComments ?? [sampleComment(11, workId: workId, replyCount: 1)],
      nextUrl: null,
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
    final query = CommentFeedQuery.replies(
      workId: workId,
      kind: kind,
      rootCommentId: rootCommentId,
    );
    requests.add(query);
    return CommentPage(
      comments:
          replies ??
          [
            sampleComment(
              12,
              workId: workId,
              parentCommentId: rootCommentId,
              rootCommentId: rootCommentId,
            ),
          ],
      nextUrl: null,
    );
  }

  @override
  bool validateCursor(CommentFeedQuery query, {required String cursor}) => true;

  @override
  Future<CommentEntity> addComment(
    CommentAddRequest request, {
    CancelToken? cancelToken,
  }) {
    final completer = addCompleter;
    if (completer != null) return completer.future;
    final error = addError;
    if (error != null) return Future.error(error);
    return Future.value(sampleComment(20));
  }

  @override
  Future<void> deleteComment(
    int commentId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    CancelToken? cancelToken,
  }) async {
    deleteCalls++;
  }
}
