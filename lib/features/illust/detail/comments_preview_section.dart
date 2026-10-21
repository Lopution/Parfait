import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/format/app_format.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/person_avatar.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/author_badge.dart';
import '../../../app/widgets/comment_text.dart';
import '../../../app/widgets/edge_icon_buttons.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/skeleton/func_skeleton.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/comments/comment_feed_controller.dart';
import '../../../core/comments/comment_models.dart';
import '../../../core/comments/comment_store.dart';
import '../../../core/entity/comment_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../l10n/context.dart';
import '../../../app/widgets/comment_composer.dart';
import 'on_demand_sliver.dart';
import 'widgets/detail_section_header.dart';

/// The comment section under the info block: an entry that opens the
/// page's composer, then the first few comments, each opening the
/// comments page, as does "See all". It reads the comments page's own
/// feed and index, so a comment sent from either shows in both. Requested
/// only once on screen ([OnDemandSliver]); the loaded preview fades in
/// over its skeleton.
class CommentsPreviewSlivers extends ConsumerWidget {
  const CommentsPreviewSlivers({
    super.key,
    required this.illustId,
    required this.onCompose,
  });

  /// Comments shown before "See all".
  static const shown = 3;

  /// The body's height while nothing is requested: the entry and two rows.
  static const _pendingHeight =
      _CommentEntry.height + FuncSpacing.sm + 2 * _PreviewTile.restingHeight;

  final int illustId;

  /// Opens the page's composer on the keyboard or a panel.
  final ValueChanged<CommentComposerInputState> onCompose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = CommentFeedQuery.root(workId: illustId);
    void openAll() => openIllustComments(context, illustId);
    // Known closed, the comments are pixiv's notice: none is asked for.
    if (commentsClosedFor(
      ref.watch(commentsClosedProvider),
      ref.read(illustStoreProvider),
      query,
    )) {
      return const SliverToBoxAdapter(child: _ClosedComments());
    }
    final count =
        ref.watch(commentTotalsProvider.select((t) => t[query.workKey])) ??
        ref.read(illustStoreProvider).get(illustId)?.totalComments;
    final loaded = ref.watch(
      commentStoreProvider.select((store) => store.idsFor(query).isNotEmpty),
    );
    // "See all" only over comments there are: counted or on hand.
    final header = DetailSectionHeader(
      title: count == null || count == 0
          ? context.l10n.commentTitle
          : context.l10n.commentTitleCount(AppFormat.count(context, count)),
      actionLabel: (count ?? 0) > 0 || loaded
          ? context.l10n.detailViewAll
          : null,
      onAction: openAll,
    );
    return OnDemandSliver(
      id: 'comments-$illustId',
      alreadyRequested: () => ref.exists(commentFeedProvider(query)),
      placeholder: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: _pendingHeight),
        ],
      ),
      sliver: (context) => SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            _PreviewBody(
              query: query,
              onOpenAll: openAll,
              onCompose: onCompose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The section of a work whose author turned comments off: its heading
/// and a line saying so.
class _ClosedComments extends StatelessWidget {
  const _ClosedComments();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      key: const Key('illust-comments-closed'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSectionHeader(title: context.l10n.commentTitle),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: muted),
              const SizedBox(width: FuncSpacing.sm),
              Expanded(
                child: Text(
                  context.l10n.commentsClosed,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _PreviewKind { loading, error, empty, comments }

class _PreviewBody extends ConsumerWidget {
  const _PreviewBody({
    required this.query,
    required this.onOpenAll,
    required this.onCompose,
  });

  final CommentFeedQuery query;
  final VoidCallback onOpenAll;
  final ValueChanged<CommentComposerInputState> onCompose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(commentFeedProvider(query));
    final store = ref.watch(commentStoreProvider);
    final work = ref.read(illustStoreProvider).get(query.workId);
    final state = async.asData?.value;
    final comments = store
        .getAll(store.idsFor(query))
        .take(CommentsPreviewSlivers.shown)
        .toList();
    final kind = switch (state) {
      _ when comments.isNotEmpty => _PreviewKind.comments,
      null when async.hasError => _PreviewKind.error,
      null => _PreviewKind.loading,
      _ when state.showInitialError => _PreviewKind.error,
      _ when state.showInitialSpinner => _PreviewKind.loading,
      _ => _PreviewKind.empty,
    };
    final l10n = context.l10n;
    Widget entry(String hint) =>
        _CommentEntry(hint: hint, onCompose: onCompose);
    return AutoRetry(
      failed: kind == _PreviewKind.error,
      error: state == null ? async.error : state.initialError,
      onRetry: () =>
          ref.read(commentFeedProvider(query).notifier).retryInitial(),
      child: Padding(
        // A note row ends in a text button: its label, not its 12dp
        // padding, ends on the margin (LAYOUT-15).
        padding: kind == _PreviewKind.error
            ? const EdgeInsetsDirectional.only(
                start: FuncSpacing.lg,
                end: FuncSpacing.lg - EdgeIconButtons.glyphInset,
              )
            : const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
        child: switch (kind) {
          // The entry shows while loading only on a work known to take
          // comments; otherwise its place is held, so nothing shifts.
          _PreviewKind.loading => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (work?.commentsClosed == false)
                entry(l10n.commentInput)
              else
                const SizedBox(height: _CommentEntry.height),
              const SizedBox(height: FuncSpacing.sm),
              FuncSkeleton(
                label: l10n.contentLoading,
                child: const _PreviewBones(),
              ),
            ],
          ),
          _PreviewKind.error => _NoteRow(
            text: l10n.commentLoadFailed,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            actionLabel: l10n.retry,
            onAction: () =>
                ref.read(commentFeedProvider(query).notifier).retryInitial(),
          ),
          _PreviewKind.empty => entry(l10n.commentFirst),
          _PreviewKind.comments => Column(
            key: const Key('illust-comments-preview'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              entry(l10n.commentInput),
              const SizedBox(height: FuncSpacing.sm),
              for (final comment in comments)
                _PreviewTile(
                  comment: comment,
                  byAuthor: comment.user.id == work?.user.id,
                  onTap: onOpenAll,
                ),
            ],
          ),
        },
      ),
    );
  }
}

/// The way into the page's composer: the signed-in user's avatar and a
/// hint on a pill, with the stamp key at its end opening the stamp panel
/// at once. One button to a screen reader, the stamp key a second.
class _CommentEntry extends ConsumerWidget {
  const _CommentEntry({required this.hint, required this.onCompose});

  static const height = 48.0;

  final String hint;
  final ValueChanged<CommentComposerInputState> onCompose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final avatarUrl = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.profileImageUrl,
      ),
    );
    return Material(
      key: const Key('illust-comment-entry'),
      // A step above the page ground, so the pill reads as a control.
      color: theme.colorScheme.surfaceContainerHigh,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: context.l10n.commentInput,
              excludeSemantics: true,
              child: InkWell(
                onTap: () => onCompose(CommentComposerInputState.keyboard),
                // At least [height]; taller when large text wraps the hint.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: height),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: FuncSpacing.sm,
                      top: FuncSpacing.xxs,
                      bottom: FuncSpacing.xxs,
                    ),
                    child: Row(
                      children: [
                        PersonAvatar(imageUrl: avatarUrl, radius: 16),
                        const SizedBox(width: FuncSpacing.md),
                        Expanded(
                          // Wraps in full on a narrow screen in a long
                          // language; the pill grows with it.
                          child: Text(
                            hint,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.commentStamps,
            onPressed: () => onCompose(CommentComposerInputState.stamp),
            icon: const Icon(Icons.image_outlined),
          ),
        ],
      ),
    );
  }
}

/// One comment, compact: avatar, name (marked when the work's author
/// wrote it), two lines of text or the stamp.
class _PreviewTile extends StatelessWidget {
  const _PreviewTile({
    required this.comment,
    required this.byAuthor,
    required this.onTap,
  });

  /// A row of one text line or less: avatar height and its padding.
  static const restingHeight = 32.0 + 2 * FuncSpacing.sm;

  final CommentEntity comment;
  final bool byAuthor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: FuncShape.control,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
      child: _content(context),
    ),
  );

  Widget _content(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final stampUrl = comment.stampUrl;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PersonAvatar(imageUrl: comment.user.profileImageUrl, radius: 16),
        const SizedBox(width: FuncSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      commentAuthorDisplayName(context, comment.user),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelLarge,
                    ),
                  ),
                  if (byAuthor) ...[
                    const SizedBox(width: FuncSpacing.xs),
                    const AuthorBadge(),
                  ],
                ],
              ),
              const SizedBox(height: FuncSpacing.xxs),
              if (comment.stampId != null && stampUrl != null)
                PixivImage.feed(
                  stampUrl,
                  layoutWidth: 80,
                  width: 80,
                  height: 48,
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                )
              else
                CommentText(
                  comment.content,
                  maxLines: 2,
                  style: textTheme.bodyMedium,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewBones extends StatelessWidget {
  const _PreviewBones();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    Widget row() => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonBone.circle(diameter: 32),
        const SizedBox(width: FuncSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: SkeletonBone.text(style: textTheme.labelLarge),
              ),
              const SizedBox(height: FuncSpacing.xxs),
              SkeletonBone.text(style: textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
    return Column(
      children: [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
            child: row(),
          ),
      ],
    );
  }
}

/// A one-line state (failed) with its action.
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.text,
    required this.style,
    required this.actionLabel,
    required this.onAction,
  });

  final String text;
  final TextStyle? style;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(text, style: style)),
      TextButton(onPressed: onAction, child: Text(actionLabel)),
    ],
  );
}
