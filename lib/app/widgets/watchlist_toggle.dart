import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watchlist/watchlist_actions.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';
import '../haptics/app_haptics.dart';
import '../motion/state_icon_switcher.dart';
import 'errors/error_details.dart';
import '../icons/app_icons.dart';

/// Shared 追更/取消追更 toggle for series surfaces (illust series header and
/// the novel series bar). The watchlist store shadows the series payload's
/// `watchlist_added` once a local observation or toggle exists.
class WatchlistToggle extends ConsumerWidget {
  const WatchlistToggle({
    super.key,
    required this.seriesKey,
    this.detailAdded,
    this.iconOnly = false,
  });

  final WatchlistKey seriesKey;

  /// `watchlist_added` carried by the series detail payload; the store's
  /// own observation wins once present.
  final bool? detailAdded;

  /// Icon-only variant for compact bars.
  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = seriesKey;
    final entry = ref.watch(
      watchlistStoreProvider.select((state) => state[key]),
    );
    // Seed the store from the detail payload the first time it is seen.
    if (detailAdded != null && entry == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(watchlistStoreProvider.notifier)
            .observeRemote(key, added: detailAdded);
      });
    }
    final added = entry?.shown ?? detailAdded ?? false;
    final icon = Icon(
      added ? AppIcons.watchlistAdded : AppIcons.watchlistAdd,
      size: iconOnly ? null : 18,
    );

    if (iconOnly) {
      return IconButton(
        tooltip: added
            ? context.l10n.watchlistRemove
            : context.l10n.watchlistAdd,
        onPressed: () => _toggle(context, ref, key),
        icon: StateIconSwitcher(value: added, child: icon),
      );
    }
    return OutlinedButton.icon(
      onPressed: () => _toggle(context, ref, key),
      icon: StateIconSwitcher(value: added, child: icon),
      label: Text(
        added ? context.l10n.watchlistRemove : context.l10n.watchlistAdd,
      ),
    );
  }

  /// The toggle flips on this frame (optimistic), so its haptic plays now;
  /// a failure rolls it back with an error haptic and a prompt that outlives
  /// this widget (FB-09, FB-15).
  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    WatchlistKey key,
  ) async {
    // Read up front: the toggle may outlive this widget.
    final reportFailure = deferErrorSnackBar(
      context,
      action: context.l10n.watchlistFailed,
    );
    final store = ref.read(watchlistStoreProvider.notifier);
    final shown = store.entryOf(key)?.shown ?? detailAdded ?? false;
    shown ? AppHaptics.toggleOff() : AppHaptics.toggleOn();
    await ref.read(watchlistActionsProvider).toggle(key);
    if (store.entryOf(key)?.error case final error?) {
      AppHaptics.error();
      reportFailure(error);
    }
  }
}
