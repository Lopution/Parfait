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
/// for a comment on the work, at the page's bottom.
///
/// It lives on its input surface ([CommentComposer.onGone]): it rides the
/// keyboard or panel up, and goes down with it. A touch anywhere outside
/// sends it down and goes on to scroll, page or open what it landed on;
/// a send, back or the page swiped away send it down too, as does the
/// keyboard put away on its own. [onClose] follows once it is down;
/// unsent text stays as the work's draft.
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
    void dismiss() => composerKey.currentState?.dismiss();
    if (!DetailPageActivity.of(context)) {
      // Not during build: going down rebuilds the composer.
      WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
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
      dismiss();
    }

    // Only the composer takes hits: the rest of the layer lets every touch
    // through to the page.
    return Align(
      alignment: Alignment.bottomCenter,
      child: TapRegion(
        onTapOutside: (_) => dismiss(),
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
          onGone: onClose,
        ),
      ),
    );
  }
}
