import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/replica_page_route.dart';
import '../../core/comments/comment_actions.dart';
import '../../core/comments/comment_feed_controller.dart';
import '../../core/comments/comment_models.dart';
import '../../core/comments/comment_store.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/network/api_error.dart';
import '../../core/paging/paged_feed_controller.dart';
import 'comment_input.dart';
import 'comment_item.dart';
import 'comment_text.dart';

void showIllustComments(BuildContext context, int illustId) {
  if (illustId <= 0) return;
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => IllustCommentsPage(illustId: illustId),
    ),
  );
}

void showCommentReplies(BuildContext context, CommentEntity rootComment) {
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => CommentRepliesPage(rootComment: rootComment),
    ),
  );
}

class IllustCommentsPage extends ConsumerStatefulWidget {
  const IllustCommentsPage({super.key, required this.illustId});

  final int illustId;

  @override
  ConsumerState<IllustCommentsPage> createState() => _IllustCommentsPageState();
}

class _IllustCommentsPageState extends ConsumerState<IllustCommentsPage> {
  CommentEntity? _replyTarget;

  CommentFeedQuery get _query =>
      CommentFeedQuery.root(illustId: widget.illustId);

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(commentStoreProvider);
    final mutationKey = 'send:${widget.illustId}:${_replyTarget?.id ?? 'root'}';
    final sending = store.mutations[mutationKey]?.pending == true;
    return Scaffold(
      appBar: AppBar(title: Text(commentText(context, 'commentTitle'))),
      body: Column(
        children: [
          Expanded(
            child: _CommentFeedView(
              query: _query,
              onReply: (comment) => setState(() => _replyTarget = comment),
              onOpenReplies: (comment) => showCommentReplies(context, comment),
              onDelete: _deleteComment,
            ),
          ),
          CommentComposer(
            replyTo: _replyTarget?.user.name,
            onCancelReply: () => setState(() => _replyTarget = null),
            sending: sending,
            onSend: (text) => _send(text: text, target: _replyTarget),
            onStampSend: (stampId) =>
                _send(stampId: stampId, target: _replyTarget),
            onError: _showMutationError,
          ),
        ],
      ),
    );
  }

  Future<void> _send({
    String? text,
    int? stampId,
    required CommentEntity? target,
  }) async {
    await ref
        .read(commentActionsProvider)
        .send(
          CommentAddRequest(
            illustId: widget.illustId,
            parentCommentId: target?.id,
            rootCommentId: target?.rootCommentId,
            text: text,
            stampId: stampId,
          ),
        );
  }

  void _showMutationError(Object error) {
    if (!mounted) return;
    final key = error is CommentPermissionException
        ? 'commentPermissionDenied'
        : 'commentSendFailed';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(commentText(context, key))));
  }

  void _deleteComment(CommentEntity comment) {
    unawaited(_confirmAndDelete(comment));
  }

  Future<void> _confirmAndDelete(CommentEntity comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(commentText(context, 'commentDelete')),
        content: Text(commentText(context, 'commentDeleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(commentText(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(commentText(context, 'confirm')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await ref.read(commentActionsProvider).delete(comment);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(commentText(context, 'commentDeleteFailed'))),
      );
    }
  }
}

class CommentRepliesPage extends ConsumerStatefulWidget {
  const CommentRepliesPage({super.key, required this.rootComment});

  final CommentEntity rootComment;

  @override
  ConsumerState<CommentRepliesPage> createState() => _CommentRepliesPageState();
}

class _CommentRepliesPageState extends ConsumerState<CommentRepliesPage> {
  late CommentEntity _replyTarget = widget.rootComment;

  CommentFeedQuery get _query => CommentFeedQuery.replies(
    illustId: widget.rootComment.illustId,
    rootCommentId: widget.rootComment.id,
  );

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(commentStoreProvider);
    final mutationKey =
        'send:${widget.rootComment.illustId}:${_replyTarget.id}';
    final sending = store.mutations[mutationKey]?.pending == true;
    final root = store.get(widget.rootComment.id) ?? widget.rootComment;
    return Scaffold(
      appBar: AppBar(title: Text(commentText(context, 'commentReplies'))),
      body: Column(
        children: [
          Expanded(
            child: Column(
              children: [
                CommentItem(
                  comment: root,
                  onReply: () => setState(() => _replyTarget = root),
                  onDelete: () => _deleteComment(root),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      commentText(context, 'commentReplies'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                Expanded(
                  child: _CommentFeedView(
                    query: _query,
                    onReply: (comment) =>
                        setState(() => _replyTarget = comment),
                    onDelete: _deleteComment,
                  ),
                ),
              ],
            ),
          ),
          CommentComposer(
            replyTo: _replyTarget.user.name,
            onCancelReply: () => setState(() => _replyTarget = root),
            sending: sending,
            onSend: (text) => _send(text: text),
            onStampSend: (stampId) => _send(stampId: stampId),
            onError: _showMutationError,
          ),
        ],
      ),
    );
  }

  Future<void> _send({String? text, int? stampId}) async {
    await ref
        .read(commentActionsProvider)
        .send(
          CommentAddRequest(
            illustId: widget.rootComment.illustId,
            parentCommentId: _replyTarget.id,
            rootCommentId: widget.rootComment.id,
            text: text,
            stampId: stampId,
          ),
        );
  }

  void _showMutationError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(commentText(context, 'commentSendFailed'))),
    );
  }

  void _deleteComment(CommentEntity comment) {
    unawaited(_confirmAndDelete(comment));
  }

  Future<void> _confirmAndDelete(CommentEntity comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(commentText(context, 'commentDelete')),
        content: Text(commentText(context, 'commentDeleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(commentText(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(commentText(context, 'confirm')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await ref.read(commentActionsProvider).delete(comment);
      if (mounted && comment.id == widget.rootComment.id) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(commentText(context, 'commentDeleteFailed'))),
      );
    }
  }
}

class _CommentFeedView extends ConsumerWidget {
  const _CommentFeedView({
    required this.query,
    required this.onReply,
    required this.onDelete,
    this.onOpenReplies,
  });

  final CommentFeedQuery query;
  final ValueChanged<CommentEntity> onReply;
  final ValueChanged<CommentEntity> onDelete;
  final ValueChanged<CommentEntity>? onOpenReplies;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(commentFeedProvider(query));
    final store = ref.watch(commentStoreProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _CommentError(
        error: error,
        onRetry: () => ref.invalidate(commentFeedProvider(query)),
      ),
      data: (feed) {
        final comments = store.getAll(store.idsFor(query));
        if (feed.showInitialError && comments.isEmpty) {
          return _CommentError(
            error: feed.initialError ?? const ApiParseError('unknown error'),
            onRetry: () =>
                ref.read(commentFeedProvider(query).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner && comments.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (comments.isEmpty && feed.isEmptyAndReady) {
          return Center(child: Text(commentText(context, 'commentNoResults')));
        }
        return RefreshIndicator(
          onRefresh: () =>
              ref.read(commentFeedProvider(query).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollEndNotification &&
                  notification.metrics.extentAfter < 300) {
                ref.read(commentFeedProvider(query).notifier).loadMore();
              }
              return false;
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: comments.length + 1,
              itemBuilder: (context, index) {
                if (index == comments.length) {
                  return _CommentFeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(commentFeedProvider(query).notifier)
                        .retryLoadMore(),
                  );
                }
                final comment = comments[index];
                return CommentItem(
                  key: ValueKey(comment.id),
                  comment: comment,
                  onReply: () => onReply(comment),
                  onOpenReplies: onOpenReplies == null
                      ? null
                      : () => onOpenReplies!(comment),
                  onDelete: () => onDelete(comment),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _CommentFeedTail extends StatelessWidget {
  const _CommentFeedTail({required this.feed, required this.onRetry});

  final PagedFeedState feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (feed.showLoadMoreSpinner) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (feed.showLoadMoreError) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(commentText(context, 'commentLoadMoreFailed')),
        ),
      );
    }
    return const SizedBox(height: 12);
  }
}

class _CommentError extends StatelessWidget {
  const _CommentError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 10),
            Text(
              commentText(context, 'commentLoadFailed'),
              textAlign: TextAlign.center,
            ),
            if (error is ApiError) ...[
              const SizedBox(height: 6),
              Text(
                error.toString(),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: onRetry,
              child: Text(commentText(context, 'retry')),
            ),
          ],
        ),
      ),
    );
  }
}
