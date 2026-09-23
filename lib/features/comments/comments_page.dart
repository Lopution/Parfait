import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/app_overlays.dart';
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

class CommentsPage extends ConsumerStatefulWidget {
  const CommentsPage({
    super.key,
    required this.workId,
    this.kind = CommentWorkKind.illust,
  });

  final int workId;
  final CommentWorkKind kind;

  @override
  ConsumerState<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends ConsumerState<CommentsPage> {
  CommentEntity? _replyTarget;
  final _composerKey = GlobalKey<CommentComposerState>();

  CommentFeedQuery get _query =>
      CommentFeedQuery.root(workId: widget.workId, kind: widget.kind);

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(commentStoreProvider);
    final mutationKey =
        'send:${widget.kind.name}:${widget.workId}:${_replyTarget?.id ?? 'root'}';
    final sending = store.mutations[mutationKey]?.pending == true;
    return Scaffold(
      // Manual insets: the composer reserves the IME/panel extent in layout
      // instead of letting the Scaffold squeeze the whole body.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(context.l10n.commentTitle)),
      body: Column(
        children: [
          Expanded(
            child: _CommentFeedView(
              query: _query,
              onReply: _replyTo,
              onOpenReplies: (comment) => openCommentReplies(context, comment),
              onDelete: _deleteComment,
            ),
          ),
          CommentComposer(
            key: _composerKey,
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
            workId: widget.workId,
            kind: widget.kind,
            parentCommentId: target?.id,
            rootCommentId: target?.rootCommentId,
            text: text,
            stampId: stampId,
          ),
        );
    // A successful send drops the reply target — but only when the user has
    // not re-targeted while the request was in flight.
    if (mounted &&
        (identical(_replyTarget, target) || _replyTarget?.id == target?.id)) {
      setState(() => _replyTarget = null);
    }
  }

  /// Reply pill on a feed row: pin the target and raise the keyboard so
  /// typing lands in the composer without a second tap.
  void _replyTo(CommentEntity comment) {
    setState(() => _replyTarget = comment);
    _composerKey.currentState?.focusForReply();
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
    final confirmed = await showAppDialog<bool>(
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
    required this.workId,
    required this.rootCommentId,
    this.kind = CommentWorkKind.illust,
    this.rootComment,
  });

  final int workId;
  final CommentWorkKind kind;
  final int rootCommentId;
  final CommentEntity? rootComment;

  @override
  ConsumerState<CommentRepliesPage> createState() => _CommentRepliesPageState();
}

class _CommentRepliesPageState extends ConsumerState<CommentRepliesPage> {
  CommentEntity? _replyTarget;
  final _composerKey = GlobalKey<CommentComposerState>();

  CommentFeedQuery get _query => CommentFeedQuery.replies(
    workId: widget.workId,
    kind: widget.kind,
    rootCommentId: widget.rootCommentId,
  );

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(commentStoreProvider);
    final root = store.get(widget.rootCommentId) ?? widget.rootComment;
    final replyTarget = _replyTarget ?? root;
    final mutationKey =
        'send:${widget.kind.name}:${widget.workId}:${replyTarget?.id ?? widget.rootCommentId}';
    final sending = store.mutations[mutationKey]?.pending == true;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(context.l10n.commentReplies)),
      body: Column(
        children: [
          Expanded(
            child: _CommentFeedView(
              query: _query,
              // The root comment and the section title ride the list's first
              // slot: they scroll away like every other row, and the composer
              // reply bar keeps the reply context visible meanwhile.
              header: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (root != null)
                    CommentItem(
                      comment: root,
                      onReply: () => _replyTo(root),
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
                ],
              ),
              onReply: _replyTo,
              onDelete: _deleteComment,
            ),
          ),
          CommentComposer(
            key: _composerKey,
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

  void _replyTo(CommentEntity comment) {
    setState(() => _replyTarget = comment);
    _composerKey.currentState?.focusForReply();
  }

  Future<void> _send({String? text, int? stampId}) async {
    final target = _replyTarget;
    await ref
        .read(commentActionsProvider)
        .send(
          CommentAddRequest(
            workId: widget.workId,
            kind: widget.kind,
            parentCommentId: target?.id ?? widget.rootCommentId,
            rootCommentId: widget.rootCommentId,
            text: text,
            stampId: stampId,
          ),
        );
    if (mounted &&
        (identical(_replyTarget, target) || _replyTarget?.id == target?.id)) {
      setState(() => _replyTarget = null);
    }
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
    final confirmed = await showAppDialog<bool>(
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
    this.header,
  });

  final CommentFeedQuery query;
  final ValueChanged<CommentEntity> onReply;
  final ValueChanged<CommentEntity> onDelete;
  final ValueChanged<CommentEntity>? onOpenReplies;

  /// Optional leading slot scrolled with the feed — the replies page passes
  /// the root comment plus the section title so a long root no longer pins
  /// the reply list to a sliver. Non-list states still render it statically
  /// above them, preserving the pre-merge visibility contract.
  final Widget? header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(commentFeedProvider(query));
    final store = ref.watch(commentStoreProvider);
    return async.when(
      loading: () => _withHeader(const FeedLoading()),
      error: (error, _) => _withHeader(
        FeedError(
          title: context.l10n.commentLoadFailed,
          retryLabel: context.l10n.retry,
          onRetry: () => ref.invalidate(commentFeedProvider(query)),
        ),
      ),
      data: (feed) {
        final comments = store.getAll(store.idsFor(query));
        if (feed.showInitialError && comments.isEmpty) {
          return _withHeader(
            FeedError(
              title: context.l10n.commentLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.retry,
              onRetry: () =>
                  ref.read(commentFeedProvider(query).notifier).retryInitial(),
            ),
          );
        }
        if (feed.showInitialSpinner && comments.isEmpty) {
          return _withHeader(const FeedLoading());
        }
        if (comments.isEmpty && feed.isEmptyAndReady) {
          return _withHeader(
            ReplicaEmptyState(
              message: context.l10n.commentNoResults,
              retryLabel: context.l10n.retry,
              onRetry: () =>
                  ref.read(commentFeedProvider(query).notifier).refresh(),
              icon: Icons.comment_outlined,
            ),
          );
        }
        return PullToRefresh(
          onRefresh: () =>
              ref.read(commentFeedProvider(query).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(commentFeedProvider(query).notifier).loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => ListView.builder(
                controller: controller,
                physics: physics,
                // Constant breathing room only: the composer's bottom extent
                // already reserves the IME/panel space in layout, so the
                // list tail never needs an extra inset pad.
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: comments.length + 1 + (header == null ? 0 : 1),
                itemBuilder: (context, index) {
                  final offset = header == null ? 0 : 1;
                  if (index < offset) return header!;
                  final itemIndex = index - offset;
                  if (itemIndex == comments.length) {
                    return FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(commentFeedProvider(query).notifier)
                          .retryLoadMore(),
                      retryLabel: context.l10n.commentLoadMoreFailed,
                    );
                  }
                  final comment = comments[itemIndex];
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

  /// Non-list states keep the header leading them — same visibility the
  /// replies page had before the root joined the scrollable. The whole
  /// region scrolls so a root taller than the viewport cannot squeeze the
  /// state into an overflowing sliver.
  Widget _withHeader(Widget child) {
    final header = this.header;
    if (header == null) return child;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: Column(
          children: [
            header,
            SizedBox(height: constraints.maxHeight, child: child),
          ],
        ),
      ),
    );
  }
}
