import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/mute/mute_models.dart';
import '../../core/mute/mute_store.dart';
import '../../l10n/context.dart';
import 'app_snack_bar.dart';
import 'errors/error_details.dart';
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

/// Mutes or unmutes [user] from a menu (a work card's, the detail page's,
/// a profile's): a mute says it landed, an unmute offers Undo, a failed
/// write says why.
Future<void> toggleUserMute(BuildContext context, MutedUser user) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final wasMuted = container.read(muteStoreProvider).isUserMuted(user.userId);
  final confirm = muteConfirmation(context);
  try {
    await container.read(muteStoreProvider.notifier).toggleUser(user);
  } catch (error) {
    if (context.mounted) {
      showErrorSnackBar(context, action: context.l10n.muteFailed, error: error);
    }
    return;
  }
  if (!wasMuted) {
    confirm();
  } else if (context.mounted) {
    showUnmuteUndo(context, MuteKey.user(user.userId), user: user);
  }
}

/// Says a mute landed: on the detail page and a profile nothing else
/// changes. Taken before the write, so it lands even if the context that
/// asked is gone by then.
VoidCallback muteConfirmation(BuildContext context) =>
    deferAppSnackBar(context, context.l10n.muteAdded);
