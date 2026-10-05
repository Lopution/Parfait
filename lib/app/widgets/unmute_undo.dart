import 'package:material_ui/material_ui.dart';

import '../../core/mute/mute_models.dart';
import '../../core/mute/mute_store.dart';
import '../../l10n/context.dart';
import 'undo_snack_bar.dart';

/// Offers Undo after [key] was unmuted: Undo mutes it again. A user mute
/// needs the [user] payload to re-create the entry. The store only has
/// toggles, so Undo skips an entry that is muted again by then — toggling
/// it would unmute it.
void showUnmuteUndo(BuildContext context, MuteKey key, {MutedUser? user}) {
  assert(
    key.kind != MuteKind.user || user?.userId.toString() == key.value,
    'a user unmute passes the removed user',
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
          final id = int.parse(key.value);
          if (!state.isWorkMuted(id)) await store.toggleWork(id);
      }
    },
  );
}
