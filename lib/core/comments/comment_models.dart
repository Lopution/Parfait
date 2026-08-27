import 'package:flutter/foundation.dart';

import '../entity/comment_entity.dart';
import '../mutation/mutation_models.dart';
import '../network/pixiv_http_client.dart';

/// Identifies either the root comment feed of a work or one reply thread.
@immutable
class CommentFeedQuery {
  const CommentFeedQuery({required this.illustId, this.rootCommentId})
    : assert(illustId > 0),
      assert(rootCommentId == null || rootCommentId > 0);

  const CommentFeedQuery.root({required int illustId})
    : this(illustId: illustId);

  const CommentFeedQuery.replies({
    required int illustId,
    required int rootCommentId,
  }) : this(illustId: illustId, rootCommentId: rootCommentId);

  final int illustId;
  final int? rootCommentId;

  bool get isReplies => rootCommentId != null;

  String get cacheKey => isReplies
      ? 'illust:$illustId:replies:$rootCommentId'
      : 'illust:$illustId:comments';

  @override
  bool operator ==(Object other) =>
      other is CommentFeedQuery &&
      other.illustId == illustId &&
      other.rootCommentId == rootCommentId;

  @override
  int get hashCode => Object.hash(illustId, rootCommentId);

  @override
  String toString() => 'CommentFeedQuery($cacheKey)';
}

@immutable
class CommentPage {
  const CommentPage({required this.comments, required this.nextUrl});

  final List<CommentEntity> comments;
  final String? nextUrl;
}

/// Input to the single comment-add endpoint. [rootCommentId] is local thread
/// context used to normalize the response; [parentCommentId] is the actual
/// server-side parent sent in the request.
@immutable
class CommentAddRequest {
  const CommentAddRequest({
    required this.illustId,
    this.parentCommentId,
    this.rootCommentId,
    this.text,
    this.stampId,
  }) : assert(illustId > 0),
       assert(parentCommentId == null || parentCommentId > 0),
       assert(rootCommentId == null || rootCommentId > 0),
       assert(stampId == null || stampId > 0);

  final int illustId;
  final int? parentCommentId;
  final int? rootCommentId;
  final String? text;
  final int? stampId;

  String? get normalizedText {
    final value = text?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  bool get hasContent => normalizedText != null || stampId != null;

  void validate() {
    if (!hasContent) {
      throw const FormatException('comment requires text or a stamp');
    }
    if (rootCommentId != null && parentCommentId == null) {
      throw const FormatException('reply requires a parent comment id');
    }
  }
}

enum CommentMutationKind { send, delete }

@immutable
class CommentSendOperation {
  const CommentSendOperation({
    required this.illustId,
    required this.parentCommentId,
    required this.rootCommentId,
    required this.envelope,
  });

  final int illustId;
  final int? parentCommentId;
  final int? rootCommentId;
  final MutationEnvelope envelope;

  int get revision => envelope.revision;

  CancelToken get cancelToken => envelope.cancelToken;

  String get key => 'send:$illustId:${parentCommentId ?? 'root'}';

  @override
  String toString() => 'CommentSendOperation(#$revision $key)';
}

@immutable
class CommentDeleteOperation {
  const CommentDeleteOperation({
    required this.commentId,
    required this.envelope,
  });

  final int commentId;
  final MutationEnvelope envelope;

  int get revision => envelope.revision;

  CancelToken get cancelToken => envelope.cancelToken;

  String get key => 'delete:$commentId';

  @override
  String toString() => 'CommentDeleteOperation(#$revision $commentId)';
}

@immutable
class CommentMutation {
  const CommentMutation({
    required this.kind,
    required this.envelope,
    this.status = MutationStatus.pending,
    this.error,
  });

  final CommentMutationKind kind;
  final MutationEnvelope envelope;
  final MutationStatus status;
  final Object? error;

  int get revision => envelope.revision;

  bool get pending => status == MutationStatus.pending;
}
