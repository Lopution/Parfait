import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../core/auth/account_store.dart';
import '../../core/comments/comment_assets.dart';
import '../../core/comments/comment_translation.dart';
import '../../core/entity/comment_entity.dart';
import '../profile/user_page.dart';
import 'comment_text.dart';

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
                            style: const TextStyle(fontWeight: FontWeight.w600),
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
    } on CommentTranslationUnavailable {
      if (mounted) {
        setState(
          () => _translationError = commentText(
            context,
            'commentTranslationUnavailable',
          ),
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _translationError = commentText(
            context,
            'commentTranslationFailed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.comment});

  final CommentEntity comment;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        showUserPage(context, comment.user.id);
      },
      child: ClipOval(
        child: SizedBox(
          width: 42,
          height: 42,
          child: comment.user.profileImageUrl == null
              ? ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.person_outline),
                )
              : PixivImage(
                  url: comment.user.profileImageUrl!,
                  fit: BoxFit.cover,
                ),
        ),
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
          : PixivImage(
              url: comment.stampUrl!,
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
    final color = Theme.of(context).dividerColor.withAlpha(190);
    return Row(
      children: [
        if (onReply != null)
          IconButton(
            tooltip: commentText(context, 'commentReply'),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: onReply,
            icon: Icon(Icons.reply_outlined, size: 19, color: color),
          ),
        if (showTranslate && onTranslate != null)
          IconButton(
            tooltip: commentText(context, 'commentTranslate'),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: translating ? null : onTranslate,
            icon: Icon(Icons.translate_outlined, size: 18, color: color),
          ),
        if (canDelete && onDelete != null)
          IconButton(
            tooltip: commentText(context, 'commentDelete'),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, size: 18, color: color),
          ),
        const Spacer(),
        if (comment.hasReplies && onOpenReplies != null)
          TextButton.icon(
            onPressed: onOpenReplies,
            icon: const Icon(Icons.forum_outlined, size: 17),
            label: Text(
              '${commentText(context, 'commentReplies')} ${comment.replyCount}',
            ),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
      ],
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
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            commentText(context, 'commentTranslation'),
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
