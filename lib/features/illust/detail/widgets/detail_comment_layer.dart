import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/haptics/app_haptics.dart';
import '../../../../core/comments/comment_actions.dart';
import '../../../../core/comments/comment_models.dart';
import '../../../../core/comments/comment_store.dart';
import '../../../../core/settings/keyboard_heights.dart';
import '../../../../app/widgets/comment_composer.dart';
import '../detail_page_activity.dart';

/// The composer the detail page raises in place from its comment entry,
/// for a comment on the work, over a see-through barrier.
///
/// A tap on the page around it, a send, or the page swiped away closes
/// it ([onClose]); unsent text stays as the work's draft. The barrier
/// takes the taps, so nothing under it scrolls, pages or opens while the
/// composer is up; a sideways swipe still reaches the pager.
class DetailCommentLayer extends ConsumerWidget {
  const DetailCommentLayer({
    super.key,
    required this.illustId,
    required this.composerKey,
    required this.onClose,
  });

  final int illustId;
  final GlobalKey<CommentComposerState> composerKey;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!DetailPageActivity.of(context)) {
      // Not during build: closing rebuilds the page.
      WidgetsBinding.instance.addPostFrameCallback((_) => onClose());
    }
    final workKey = CommentFeedQuery.root(workId: illustId).workKey;
    final sending = ref.watch(
      commentStoreProvider.select(
        (store) =>
            store.mutations['send:illust:$illustId:root']?.pending == true,
      ),
    );
    Future<void> send({String? text, int? stampId}) async {
      await ref
          .read(commentActionsProvider)
          .send(
            CommentAddRequest(workId: illustId, text: text, stampId: stampId),
          );
      AppHaptics.success();
      onClose();
    }

    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ModalBarrier(
          onDismiss: onClose,
          semanticsLabel: MaterialLocalizations.of(
            context,
          ).modalBarrierDismissLabel,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            // Sets the composer off the page running on behind it.
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: CommentComposer(
              key: composerKey,
              sending: sending,
              onSend: (text) => send(text: text),
              onStampSend: (stampId) => send(stampId: stampId),
              onError: (error) => showCommentSendError(context, error),
              keyboardHeights: ref.watch(keyboardHeightsProvider.notifier),
              initialText: ref.read(commentDraftsProvider)[workKey] ?? '',
              onChanged: (text) =>
                  ref.read(commentDraftsProvider.notifier).keep(workKey, text),
            ),
          ),
        ),
      ],
    );
  }
}
