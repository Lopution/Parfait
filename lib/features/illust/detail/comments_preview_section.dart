import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/motion/state_fade.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/person_avatar.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/author_badge.dart';
import '../../../app/widgets/comment_text.dart';
import '../../../app/widgets/skeleton/func_skeleton.dart';
import '../../../core/comments/comment_feed_controller.dart';
import '../../../core/comments/comment_models.dart';
import '../../../core/comments/comment_store.dart';
import '../../../core/entity/comment_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../l10n/context.dart';
import 'on_demand_sliver.dart';
import 'widgets/detail_section_header.dart';

/// The first few comments under the info block, with "See all" into the
/// comments page. It reads the comments page's own feed, so opening the
/// page afterwards shows them at once. Requested only once on screen
/// ([OnDemandSliver]); the loaded preview fades in over its skeleton.
class CommentsPreviewSlivers extends ConsumerWidget {
  const CommentsPreviewSlivers({super.key, required this.illustId});

  /// Comments shown before "See all".
  static const shown = 3;

  /// The body's height while nothing is requested or loading: two rows.
  static const _pendingHeight = 112.0;

  final int illustId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = CommentFeedQuery.root(workId: illustId);
    void openAll() => openIllustComments(context, illustId);
    final header = DetailSectionHeader(
      title: context.l10n.commentTitle,
      actionLabel: context.l10n.detailViewAll,
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
            _PreviewBody(query: query, onOpenAll: openAll),
          ],
        ),
      ),
    );
  }
}

enum _PreviewKind { loading, error, empty, comments }

class _PreviewBody extends ConsumerWidget {
  const _PreviewBody({required this.query, required this.onOpenAll});

  final CommentFeedQuery query;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(commentFeedProvider(query));
    final store = ref.watch(commentStoreProvider);
    final authorId = ref.read(illustStoreProvider).get(query.workId)?.user.id;
    final state = async.asData?.value;
    final comments = [
      for (final id in state?.ids ?? const <int>[]) ?store.get(id),
    ].take(CommentsPreviewSlivers.shown).toList();
    final kind = switch (state) {
      null when async.hasError => _PreviewKind.error,
      null => _PreviewKind.loading,
      _ when state.showInitialError => _PreviewKind.error,
      _ when state.showInitialSpinner && state.ids.isEmpty =>
        _PreviewKind.loading,
      _ when comments.isEmpty => _PreviewKind.empty,
      _ => _PreviewKind.comments,
    };
    final l10n = context.l10n;
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
      child: StateFade(
        kind: kind,
        child: switch (kind) {
          _PreviewKind.loading => FuncSkeleton(
            label: l10n.contentLoading,
            child: const _PreviewBones(),
          ),
          _PreviewKind.error => _NoteRow(
            text: l10n.commentLoadFailed,
            style: muted,
            actionLabel: l10n.retry,
            onAction: () =>
                ref.read(commentFeedProvider(query).notifier).retryInitial(),
          ),
          _PreviewKind.empty => _NoteRow(
            text: l10n.commentNoResults,
            style: muted,
            actionLabel: l10n.commentInput,
            onAction: onOpenAll,
          ),
          _PreviewKind.comments => Material(
            key: const Key('illust-comments-preview'),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: FuncShape.card,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpenAll,
              child: Padding(
                padding: const EdgeInsets.all(FuncSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, comment) in comments.indexed) ...[
                      if (index > 0) const SizedBox(height: FuncSpacing.md),
                      _PreviewTile(
                        comment: comment,
                        byAuthor: comment.user.id == authorId,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        },
      ),
    );
  }
}

/// One comment, compact: avatar, name (marked when the work's author
/// wrote it), two lines of text or the stamp.
class _PreviewTile extends StatelessWidget {
  const _PreviewTile({required this.comment, required this.byAuthor});

  final CommentEntity comment;
  final bool byAuthor;

  @override
  Widget build(BuildContext context) {
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
                      comment.user.name,
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
    return Padding(
      padding: const EdgeInsets.all(FuncSpacing.md),
      child: Column(
        children: [
          row(),
          const SizedBox(height: FuncSpacing.md),
          row(),
        ],
      ),
    );
  }
}

/// A one-line state (no comments yet, failed) with its action.
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
