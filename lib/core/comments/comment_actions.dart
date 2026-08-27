import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/comment_entity.dart';
import 'comment_models.dart';
import 'comment_repository.dart';
import 'comment_store.dart';

class CommentPermissionException implements Exception {
  const CommentPermissionException();

  @override
  String toString() => 'CommentPermissionException(current user is not owner)';
}

/// UI-facing comment mutations. A server response is required before the
/// canonical store changes, so failed sends/deletes never look successful.
class CommentActions {
  CommentActions(this._ref);

  final Ref _ref;

  bool canDelete(CommentEntity comment) {
    final account = _ref.read(accountStoreProvider).value?.usableCurrent;
    return account?.userId == comment.user.id;
  }

  Future<CommentEntity?> send(CommentAddRequest request) async {
    request.validate();
    final store = _ref.read(commentStoreProvider.notifier);
    final operation = store.beginSend(
      illustId: request.illustId,
      parentCommentId: request.parentCommentId,
      rootCommentId: request.rootCommentId,
    );
    if (operation == null) return null;
    try {
      final comment = await _ref
          .read(commentRepositoryProvider)
          .addComment(request);
      store.commitSend(operation, comment);
      return comment;
    } on Object catch (error) {
      store.failSend(operation, error);
      rethrow;
    }
  }

  Future<bool> delete(CommentEntity comment) async {
    if (!canDelete(comment)) {
      throw const CommentPermissionException();
    }
    final store = _ref.read(commentStoreProvider.notifier);
    final operation = store.beginDelete(comment.id);
    if (operation == null) return false;
    try {
      await _ref.read(commentRepositoryProvider).deleteComment(comment.id);
      store.commitDelete(operation);
      return true;
    } on Object catch (error) {
      store.failDelete(operation, error);
      rethrow;
    }
  }
}

final commentActionsProvider = Provider<CommentActions>((ref) {
  return CommentActions(ref);
});
