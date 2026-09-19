import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/auth/account_store.dart';
import '../../core/comments/comment_assets.dart';
import '../../core/comments/comment_translation.dart';
import '../../core/entity/comment_entity.dart';
import '../../app/navigation/routes.dart';
import 'comment_text.dart';
import '../../l10n/context.dart';

/// One comment row. Replying is an explicit action icon; no long-press reply
/// gesture is installed, matching beta56.
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

class _CommentItemState extends ConsumerState<CommentItem> {
  bool _translating = false;
  String? _translation;
  String? _translationError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ref.watch(accountStoreProvider).value?.usableCurrent;
    final canDelete = account?.userId == widget.comment.user.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(comment: widget.comment),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.comment.user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(widget.comment.createdAt),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _CommentBody(comment: widget.comment),
                    if (_translation != null)
                      _TranslationOverlay(text: _translation!),
                    if (_translating)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    if (_translationError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _translationError!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    _Actions(
                      comment: widget.comment,
                      canDelete: canDelete,
                      showTranslate: widget.comment.content.trim().isNotEmpty,
                      translating: _translating,
                      onReply: widget.onReply,
                      onTranslate: _translate,
                      onDelete: widget.onDelete,
                      onOpenReplies: widget.onOpenReplies,
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

  Future<void> _translate() async {
    if (_translating) return;
    setState(() {
      _translating = true;
      _translationError = null;
    });
    try {
      final value = await ref
          .read(commentTranslationServiceProvider)
          .translate(
            widget.comment.content,
            targetLanguage: Localizations.localeOf(context).languageCode,
          );
      if (!mounted) return;
      setState(() => _translation = value);
    } on CommentTranslationUnavailable catch (error) {
      if (mounted) {
        setState(
          () =>
              _translationError = _translationFailureText(context, error.kind),
        );
      }
    } on CommentTranslationError catch (error) {
      if (mounted) {
        setState(
          () =>
              _translationError = _translationFailureText(context, error.kind),
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _translationError = context.l10n.commentTranslationFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }
}

String _translationFailureText(
  BuildContext context,
  CommentTranslationFailureKind kind,
) {
  switch (kind) {
    case CommentTranslationFailureKind.disabled:
    case CommentTranslationFailureKind.notConfigured:
      return context.l10n.commentTranslationUnavailable;
    case CommentTranslationFailureKind.invalidCredentials:
      return context.l10n.commentTranslationInvalidCredentials;
    case CommentTranslationFailureKind.rateLimited:
      return context.l10n.commentTranslationRateLimited;
    case CommentTranslationFailureKind.network:
    case CommentTranslationFailureKind.malformed:
    case CommentTranslationFailureKind.unsupportedLanguage:
    case CommentTranslationFailureKind.other:
      return context.l10n.commentTranslationFailed;
  }
}

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
      final stamp = commentStampIds.contains(comment.stampId)
          ? Image.asset(
              commentStampAsset(comment.stampId!),
              width: 180,
              height: 110,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            )
          : comment.stampUrl == null
          ? const Icon(Icons.image_not_supported_outlined)
          : PixivImage.feed(
              comment.stampUrl!,
              layoutWidth: 180,
              width: 180,
              height: 110,
              fit: BoxFit.contain,
            );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: stamp,
      );
    }
    if (comment.content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: CommentText(comment.content),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.comment,
    required this.canDelete,
    required this.showTranslate,
    required this.translating,
    this.onReply,
    this.onTranslate,
    this.onDelete,
    this.onOpenReplies,
  });

  final CommentEntity comment;
  final bool canDelete;
  final bool showTranslate;
  final bool translating;
  final VoidCallback? onReply;
  final VoidCallback? onTranslate;
  final VoidCallback? onDelete;
  final VoidCallback? onOpenReplies;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 8,
      children: [
        if (onReply != null)
          _ActionPill(
            icon: Icons.reply_outlined,
            label: context.l10n.commentReply,
            onTap: onReply,
          ),
        if (showTranslate && onTranslate != null)
          _ActionPill(
            icon: Icons.translate_outlined,
            label: context.l10n.commentTranslate,
            onTap: translating ? null : onTranslate,
          ),
        if (canDelete && onDelete != null)
          _ActionPill(
            icon: Icons.delete_outline,
            label: context.l10n.commentDelete,
            foreground: FuncSemanticTokens.of(context).danger,
            onTap: onDelete,
          ),
        const Spacer(),
        if (comment.hasReplies && onOpenReplies != null)
          _ActionPill(
            icon: Icons.forum_outlined,
            label: '${context.l10n.commentReplies} ${comment.replyCount}',
            onTap: onOpenReplies,
          ),
      ],
    );
  }
}

/// One comment action: a pill with icon + label, identical geometry for
/// every entry so the row's baselines and left edges always agree. Shaft's
/// cell_comment uses the same contract (v3_action_pill_bg + 12sp bold
/// label); mixing IconButton and TextButton primitives was what produced
/// the misaligned reply/translate row.
class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.icon,
    required this.label,
    this.foreground,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color? foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final color = foreground ?? tokens.contentSecondary;
    final radius = BorderRadius.circular(999);
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: Material(
        color: tokens.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: tokens.divider),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 7, 13, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TranslationOverlay extends StatelessWidget {
  const _TranslationOverlay({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.commentTranslation,
            style: TextStyle(color: theme.colorScheme.primary),
          ),
          const Divider(height: 12),
          Text(text),
        ],
      ),
    );
  }
}

String _formatDate(DateTime date) => '${date.year}/${date.month}/${date.day}';
