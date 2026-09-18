import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watchlist/watchlist_actions.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';

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
    final added = entry?.added ?? detailAdded ?? false;
    final pending = entry?.isPending == true;
    final failed = entry?.error != null;

    if (iconOnly) {
      return IconButton(
        tooltip: added
            ? context.l10n.watchlistRemove
            : context.l10n.watchlistAdd,
        onPressed: pending
            ? null
            : () => ref.read(watchlistActionsProvider).toggle(key),
        icon: pending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                added ? Icons.bookmark_added : Icons.bookmark_add_outlined,
                color: failed ? Theme.of(context).colorScheme.error : null,
              ),
      );
    }
    return OutlinedButton.icon(
      onPressed: pending
          ? null
          : () => ref.read(watchlistActionsProvider).toggle(key),
      icon: pending
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              added ? Icons.bookmark_added : Icons.bookmark_add_outlined,
              size: 18,
            ),
      label: Text(
        failed
            ? '${context.l10n.watchlistAdd} · ${context.l10n.retry}'
            : added
            ? context.l10n.watchlistRemove
            : context.l10n.watchlistAdd,
      ),
    );
  }
}
