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

/// One comment row. The work's author is marked beside the name. Reply and
/// the replies link are pill buttons under the body; translate and delete
/// sit in the header's overflow menu, and a translation opens below the
/// body. No long-press reply gesture is installed, matching beta56.
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
        account?.userId == widget.comment.user.id && widget.onDelete != null;
    final showTranslate = widget.comment.content.trim().isNotEmpty;
    final byAuthor =
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
                                  widget.comment.user.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
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
                      onReply: widget.onReply,
                      onOpenReplies: widget.onOpenReplies,
                    ),
                  ],
                ),
              ),
              // The 48dp target centers its icon on the avatar.
              if (showTranslate || canDelete)
                _MoreMenu(
                  showTranslate: showTranslate,
                  translating: translating,
                  translationShown: translationShown,
                  canDelete: canDelete,
                  onTranslate: () =>
                      unawaited(toggleTranslation([widget.comment.content])),
                  onDelete: widget.onDelete,
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

class _Avatar extends StatelessWidget {
  const _Avatar({required this.comment});

  final CommentEntity comment;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        openUser(context, comment.user.id);
      },
      // Keep comment/profile avatars on the same placeholder, cache and ring
      // contract as every other user surface.
      child: PersonAvatar(imageUrl: comment.user.profileImageUrl, radius: 21),
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

enum _CommentMenuAction { translate, delete }

/// The header's overflow menu: translate and, on the viewer's own comment,
/// delete. The caller confirms the delete — it cannot be undone.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.showTranslate,
    required this.translating,
    required this.translationShown,
    required this.canDelete,
    required this.onTranslate,
    this.onDelete,
  });

  final bool showTranslate;
  final bool translating;
  final bool translationShown;
  final bool canDelete;
  final VoidCallback onTranslate;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return AppMenuButton<_CommentMenuAction>(
      tooltip: context.l10n.commentMoreActions,
      entries: [
        if (showTranslate)
          AppMenuEntry(
            value: _CommentMenuAction.translate,
            icon: Icons.translate_outlined,
            label: translationShown
                ? context.l10n.translationHide
                : context.l10n.translateAction,
            enabled: !translating,
          ),
        if (canDelete)
          AppMenuEntry(
            value: _CommentMenuAction.delete,
            icon: Icons.delete_outline,
            label: context.l10n.commentDelete,
            destructive: true,
          ),
      ],
      onSelected: (_, action) => switch (action) {
        _CommentMenuAction.translate => onTranslate(),
        _CommentMenuAction.delete => onDelete?.call(),
      },
    );
  }
}

/// Reply and, when there are any, the link to the replies: pill buttons,
/// 32dp tall within a 48dp target, wrapping onto a second line when long
/// labels do not fit.
class _Actions extends StatelessWidget {
  const _Actions({required this.comment, this.onReply, this.onOpenReplies});

  final CommentEntity comment;
  final VoidCallback? onReply;
  final VoidCallback? onOpenReplies;

  static const _pillHeight = 32.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final showReplies = comment.hasReplies && onOpenReplies != null;
    if (onReply == null && !showReplies) return const SizedBox.shrink();
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
        ? context.l10n.commentViewReplies(comment.replyCount)
        : context.l10n.commentShowReplies;
    return OverflowBar(
      spacing: FuncSpacing.sm,
      overflowAlignment: OverflowBarAlignment.start,
      children: [
        if (onReply != null)
          TextButton(
            style: pill(colors.onSurfaceVariant),
            onPressed: onReply,
            child: Text(context.l10n.commentReply),
          ),
        if (showReplies)
          TextButton(
            style: pill(colors.primary),
            onPressed: onOpenReplies,
            child: Text(repliesLabel),
          ),
      ],
    );
  }
}
