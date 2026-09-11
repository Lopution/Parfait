import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/comments/comment_actions.dart';
import '../../core/comments/comment_feed_controller.dart';
import '../../core/comments/comment_models.dart';
import '../../core/comments/comment_store.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/network/api_error.dart';
import 'comment_input.dart';
import 'comment_item.dart';
import 'comment_text.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';

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
      appBar: AppBar(title: Text(context.l10n.commentTitle)),
      body: Column(
        children: [
          Expanded(
            child: _CommentFeedView(
              query: _query,
              onReply: (comment) => setState(() => _replyTarget = comment),
              onOpenReplies: (comment) => openCommentReplies(context, comment),
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
    showAppSnackBar(context, commentText(context, key));
  }

  void _deleteComment(CommentEntity comment) {
    unawaited(_confirmAndDelete(comment));
  }

  Future<void> _confirmAndDelete(CommentEntity comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.commentDelete),
        content: Text(context.l10n.commentDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirm),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await ref.read(commentActionsProvider).delete(comment);
    } on Object {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.commentDeleteFailed);
    }
  }
}

class CommentRepliesPage extends ConsumerStatefulWidget {
  const CommentRepliesPage({
    super.key,
    required this.illustId,
    required this.rootCommentId,
    this.rootComment,
  });

  final int illustId;
  final int rootCommentId;
  final CommentEntity? rootComment;

  @override
  ConsumerState<CommentRepliesPage> createState() => _CommentRepliesPageState();
}

class _CommentRepliesPageState extends ConsumerState<CommentRepliesPage> {
  CommentEntity? _replyTarget;

  CommentFeedQuery get _query => CommentFeedQuery.replies(
    illustId: widget.illustId,
    rootCommentId: widget.rootCommentId,
  );

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(commentStoreProvider);
    final root = store.get(widget.rootCommentId) ?? widget.rootComment;
    final replyTarget = _replyTarget ?? root;
    final mutationKey =
        'send:${widget.illustId}:${replyTarget?.id ?? widget.rootCommentId}';
    final sending = store.mutations[mutationKey]?.pending == true;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.commentReplies)),
      body: Column(
        children: [
          Expanded(
            child: Column(
              children: [
                if (root != null)
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
                      context.l10n.commentReplies,
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
            replyTo: replyTarget?.user.name,
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
            illustId: widget.illustId,
            parentCommentId: _replyTarget?.id ?? widget.rootCommentId,
            rootCommentId: widget.rootCommentId,
            text: text,
            stampId: stampId,
          ),
        );
  }

  void _showMutationError(Object error) {
    if (!mounted) return;
    showAppSnackBar(context, context.l10n.commentSendFailed);
  }

  void _deleteComment(CommentEntity comment) {
    unawaited(_confirmAndDelete(comment));
  }

  Future<void> _confirmAndDelete(CommentEntity comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.commentDelete),
        content: Text(context.l10n.commentDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirm),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await ref.read(commentActionsProvider).delete(comment);
      if (mounted && comment.id == widget.rootCommentId) {
        Navigator.of(context).pop();
      }
    } on Object {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.commentDeleteFailed);
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
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.commentLoadFailed,
        retryLabel: context.l10n.retry,
        onRetry: () => ref.invalidate(commentFeedProvider(query)),
      ),
      data: (feed) {
        final comments = store.getAll(store.idsFor(query));
        if (feed.showInitialError && comments.isEmpty) {
          return FeedError(
            title: context.l10n.commentLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () =>
                ref.read(commentFeedProvider(query).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner && comments.isEmpty) {
          return const FeedLoading();
        }
        if (comments.isEmpty && feed.isEmptyAndReady) {
          return ReplicaEmptyState(
            message: context.l10n.commentNoResults,
            retryLabel: context.l10n.retry,
            onRetry: () =>
                ref.read(commentFeedProvider(query).notifier).refresh(),
            icon: Icons.comment_outlined,
          );
        }
        return PullToRefresh(
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
            child: SmoothWheelScroll(
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => ListView.builder(
                controller: controller,
                physics: physics,
                itemCount: comments.length + 1,
                itemBuilder: (context, index) {
                  if (index == comments.length) {
                    return FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(commentFeedProvider(query).notifier)
                          .retryLoadMore(),
                      retryLabel: context.l10n.commentLoadMoreFailed,
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
          ),
        );
      },
    );
  }
}
