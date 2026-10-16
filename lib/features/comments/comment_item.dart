import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/author_badge.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/novel/novel_store.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/comment_text.dart';
import '../../app/widgets/inline_translation.dart';
import '../../l10n/context.dart';

/// One comment row. The work's author is marked beside the name. Reply,
/// the replies link and translate are pill buttons under the body, a
/// translation opens below the body, and the viewer's own comment ends
/// the pill row with a ⋮ holding delete. No long-press reply gesture is
/// installed, matching beta56.
class CommentItem extends ConsumerStatefulWidget {
  const CommentItem({
    super.key,
    required this.comment,
    this.onReply,
    this.onOpenReplies,
    this.onDelete,
  });

  final CommentEntity comment;
  final VoidCallback? onReply;
  final VoidCallback? onOpenReplies;
  final VoidCallback? onDelete;

  @override
  ConsumerState<CommentItem> createState() => _CommentItemState();
}

class _CommentItemState extends ConsumerState<CommentItem>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ref.watch(accountStoreProvider).value?.usableCurrent;
    final canDelete =
        widget.comment.user.id > 0 &&
        account?.userId == widget.comment.user.id &&
        widget.onDelete != null;
    final showTranslate = widget.comment.content.trim().isNotEmpty;
    final byAuthor =
        widget.comment.user.id > 0 &&
        _workAuthorId(ref, widget.comment) == widget.comment.user.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.md,
        FuncSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(comment: widget.comment),
              const SizedBox(width: FuncSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  commentAuthorDisplayName(
                                    context,
                                    widget.comment.user,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge,
                                ),
                              ),
                              if (byAuthor) ...[
                                const SizedBox(width: FuncSpacing.xs),
                                const AuthorBadge(),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: FuncSpacing.sm),
                        Text(
                          AppFormat.relative(context, widget.comment.createdAt),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: FuncSpacing.sm),
                    _CommentBody(comment: widget.comment),
                    // Translation, its progress or its failure open below
                    // the body instead of popping in.
                    TranslationPanel(
                      translating: translating,
                      translations: translations,
                      failure: translationFailure,
                    ),
                    _Actions(
                      comment: widget.comment,
                      translating: translating,
                      translationShown: translationShown,
                      onReply: widget.onReply,
                      onOpenReplies: widget.onOpenReplies,
                      onTranslate: showTranslate
                          ? () => unawaited(
                              toggleTranslation([widget.comment.content]),
                            )
                          : null,
                      onDelete: canDelete ? widget.onDelete : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 24),
        ],
      ),
    );
  }
}

/// The author of the work [comment] belongs to, when the work is in the
/// shared stores (it is whenever the thread was opened from its page).
int? _workAuthorId(WidgetRef ref, CommentEntity comment) =>
    switch (comment.kind) {
      CommentWorkKind.illust =>
        ref.read(illustStoreProvider).get(comment.workId)?.user.id,
      CommentWorkKind.novel => ref.watch(
        novelStoreProvider.select((novels) => novels[comment.workId]?.user.id),
      ),
    };

const _avatarRadius = 21.0;

class _Avatar extends StatelessWidget {
  const _Avatar({required this.comment});

  final CommentEntity comment;

  @override
  Widget build(BuildContext context) {
    // A circular ripple the size of the avatar: the press shows on the
    // shape that is tapped (MOTION-06).
    return InkResponse(
      onTap: comment.user.id > 0
          ? () => openUser(context, comment.user.id)
          : null,
      customBorder: const CircleBorder(),
      radius: _avatarRadius,
      // Keep comment/profile avatars on the same placeholder, cache and ring
      // contract as every other user surface.
      child: PersonAvatar(
        imageUrl: comment.user.profileImageUrl,
        radius: _avatarRadius,
      ),
    );
  }
}

class _CommentBody extends StatelessWidget {
  const _CommentBody({required this.comment});

  final CommentEntity comment;

  @override
  Widget build(BuildContext context) {
    if (comment.stampId != null) {
      final stamp = comment.stampUrl == null
          ? const Icon(Icons.image_not_supported_outlined)
          : PixivImage.feed(
              comment.stampUrl!,
              layoutWidth: 180,
              width: 180,
              height: 110,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xs),
        child: stamp,
      );
    }
    if (comment.content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xs),
      child: CommentText(comment.content),
    );
  }
}

/// Reply, the link to the replies when there are any, and translate:
/// pill buttons, 32dp tall within a 48dp target, wrapping onto a second
/// line when long labels do not fit. The viewer's own comment ends the
/// row with a ⋮ that holds delete; the caller confirms the delete — it
/// cannot be undone. The ⋮ sits here rather than beside the date, so
/// every date ends on the same edge.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.comment,
    required this.translating,
    required this.translationShown,
    this.onReply,
    this.onOpenReplies,
    this.onTranslate,
    this.onDelete,
  });

  final CommentEntity comment;
  final bool translating;
  final bool translationShown;
  final VoidCallback? onReply;
  final VoidCallback? onOpenReplies;

  /// Null when the comment has no text to translate.
  final VoidCallback? onTranslate;

  /// Null unless the comment is the viewer's own.
  final VoidCallback? onDelete;

  static const _pillHeight = 32.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = context.l10n;
    final onTranslate = this.onTranslate;
    final onDelete = this.onDelete;
    final showReplies = comment.hasReplies && onOpenReplies != null;
    if (onReply == null &&
        !showReplies &&
        onTranslate == null &&
        onDelete == null) {
      return const SizedBox.shrink();
    }
    ButtonStyle pill(Color foreground) => TextButton.styleFrom(
      foregroundColor: foreground,
      backgroundColor: colors.surfaceContainerHigh,
      shape: const StadiumBorder(),
      minimumSize: const Size(0, _pillHeight),
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.md),
      tapTargetSize: MaterialTapTargetSize.padded,
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
    // Pixiv's comment payload flags replies without counting them.
    final repliesLabel = comment.replyCount > 0
        ? l10n.commentViewReplies(comment.replyCount)
        : l10n.commentShowReplies;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          // A Wrap, not an OverflowBar: one pill too many moves to the
          // next line alone instead of stacking the whole row.
          child: Wrap(
            spacing: FuncSpacing.sm,
            children: [
              if (onReply != null)
                TextButton(
                  style: pill(colors.onSurfaceVariant),
                  onPressed: onReply,
                  child: Text(l10n.commentReply),
                ),
              if (showReplies)
                TextButton(
                  style: pill(colors.primary),
                  onPressed: onOpenReplies,
                  child: Text(repliesLabel),
                ),
              if (onTranslate != null)
                TextButton(
                  style: pill(colors.onSurfaceVariant),
                  onPressed: translating ? null : onTranslate,
                  child: Text(
                    translationShown
                        ? l10n.translationHide
                        : l10n.translateAction,
                  ),
                ),
            ],
          ),
        ),
        if (onDelete != null)
          AppMenuButton<VoidCallback>(
            tooltip: l10n.commentMoreActions,
            entries: [
              AppMenuEntry(
                value: onDelete,
                icon: Icons.delete_outline,
                label: l10n.commentDelete,
                destructive: true,
              ),
            ],
            onSelected: (_, delete) => delete(),
          ),
      ],
    );
  }
}
