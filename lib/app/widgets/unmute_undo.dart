import 'package:material_ui/material_ui.dart';

import '../../core/mute/mute_models.dart';
import '../../core/mute/mute_store.dart';
import '../../l10n/context.dart';
import 'undo_snack_bar.dart';

/// Offers Undo after [key] was unmuted: Undo mutes it again. User and
/// work mutes pass the removed [user] or [work] so Undo re-creates the
/// entry with its name, avatar, title and thumbnail. Tags and users only
/// have toggles, so Undo skips an entry that is muted again by then —
/// toggling it would unmute it.
void showUnmuteUndo(
  BuildContext context,
  MuteKey key, {
  MutedUser? user,
  MutedWork? work,
}) {
  assert(
    key.kind != MuteKind.user || user?.userId.toString() == key.value,
    'a user unmute passes the removed user',
  );
  assert(
    key.kind != MuteKind.work || work?.illustId.toString() == key.value,
    'a work unmute passes the removed work',
  );
  showUndoSnackBar(
    context,
    context.l10n.muteRemoved,
    onUndo: (container) async {
      final state = container.read(muteStoreProvider);
      final store = container.read(muteStoreProvider.notifier);
      switch (key.kind) {
        case MuteKind.tag:
          if (!state.isTagMuted(key.value)) await store.toggleTag(key.value);
        case MuteKind.user:
          if (!state.isUserMuted(user!.userId)) await store.toggleUser(user);
        case MuteKind.work:
          if (!state.isWorkMuted(work!.illustId)) await store.muteWork(work);
      }
    },
  );
}
