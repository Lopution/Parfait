import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/motion/removal.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/selectable_tile.dart';
import '../../app/widgets/selection_app_bar.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/widgets/undo_snack_bar.dart';
import '../../core/watchlater/watch_later_repository.dart';
import '../../core/watchlater/watch_later_store.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// Local watch-later list: stashed illusts render straight from the stored
/// payload — no network. Long-pressing a card offers "remove" through the
/// same action registry as the feeds; "manage" selects several to remove at
/// once, with Undo.
class WatchLaterPage extends ConsumerStatefulWidget {
  const WatchLaterPage({super.key});

  @override
  ConsumerState<WatchLaterPage> createState() => _WatchLaterPageState();
}

class _WatchLaterPageState extends ConsumerState<WatchLaterPage> {
  /// Selection mode is page-local, as on the history and download pages.
  bool _managing = false;
  final Set<int> _selected = {};
  final _removals = RemovalController();

  void _enterManaging() {
    // Entering management mode is the explicit-vibration role (§5.6).
    AppHaptics.confirm();
    setState(() => _managing = true);
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selected.clear();
    });
  }

  void _toggleSelected(int illustId) {
    AppHaptics.select();
    setState(() {
      if (!_selected.remove(illustId)) _selected.add(illustId);
    });
  }

  void _selectAll(List<WatchLaterEntry> entries) {
    AppHaptics.select();
    setState(() => _selected.addAll(entries.map((e) => e.entity.id)));
  }

  /// The tiles leave first, then the rows go in one transaction; Undo puts
  /// them back in place (D5 — no confirmation).
  Future<void> _removeSelected() async {
    final ids = List<int>.of(_selected);
    _exitManaging();
    await _removals.playExit(ids);
    final removal = await ref
        .read(watchLaterStoreProvider.notifier)
        .removeAll(ids);
    if (removal == null) {
      _removals.restore(ids);
      return;
    }
    if (!mounted) return;
    showUndoSnackBar(
      context,
      context.l10n.watchLaterRemoved,
      onUndo: (container) =>
          container.read(watchLaterStoreProvider.notifier).restoreAll(removal),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = ref.watch(watchLaterStoreProvider);
    final list = entries.value ?? const <WatchLaterEntry>[];
    // Entries removed elsewhere (a card's own action) leave the selection.
    ref.listen(watchLaterStoreProvider, (_, next) {
      final ids = {
        for (final e in next.value ?? const <WatchLaterEntry>[]) e.entity.id,
      };
      if (_selected.any((id) => !ids.contains(id))) {
        setState(() => _selected.retainAll(ids));
      }
    });
    return PopScope(
      // System back exits selection mode instead of popping the page.
      canPop: !_managing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitManaging();
      },
      child: Scaffold(
        appBar: _managing
            ? selectionAppBar(
                context,
                count: _selected.length,
                onClose: _exitManaging,
                actions: [
                  IconButton(
                    tooltip: l10n.selectAll,
                    onPressed: () => _selectAll(list),
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    tooltip: l10n.cardActionRemoveWatchLater,
                    onPressed: _selected.isEmpty ? null : _removeSelected,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              )
            : AppTopBar(
                title: Text(l10n.watchLaterTitle),
                actions: [
                  // Spelled out like every list's manage entry.
                  if (list.isNotEmpty)
                    TextButton(
                      onPressed: _enterManaging,
                      child: Text(l10n.manage),
                    ),
                ],
              ),
        body: PullToRefresh(
          onRefresh: () => ref.refresh(watchLaterStoreProvider.future),
          child: entries.when(
            loading: () => const Center(child: FeedLoading()),
            error: (error, _) => FeedError(
              title: l10n.watchLaterLoadFailed,
              error: error,
              retryLabel: l10n.retry,
              onRetry: () => ref.invalidate(watchLaterStoreProvider),
            ),
            data: (list) => list.isEmpty
                ? FeedEmpty(
                    icon: Icons.bookmark_border,
                    title: l10n.watchLaterTitle,
                    detail: l10n.watchLaterEmpty,
                  )
                : RemovalScope(
                    controller: _removals,
                    child: SmoothWheelScroll(
                      builder: (context, controller, physics) =>
                          CustomScrollView(
                            controller: controller,
                            physics: physics,
                            scrollCacheExtent: kFeedCacheExtent,
                            restorationId: 'watchlater',
                            slivers: [
                              IllustFeedGrid(
                                padding: const EdgeInsets.all(FuncSpacing.sm),
                                mainAxisSpacing: FuncSpacing.sm,
                                itemIds: [for (final e in list) e.entity.id],
                                itemCount: list.length,
                                // IllustFeedGrid already wraps each item in a
                                // StaggeredEntrance — nesting a second one
                                // doubled the opacity/offset on every card.
                                itemBuilder: (context, index) {
                                  final id = list[index].entity.id;
                                  return Removable(
                                    id: id,
                                    style: RemovalStyle.tile,
                                    child: SelectableTile(
                                      managing: _managing,
                                      selected: _selected.contains(id),
                                      onToggle: () => _toggleSelected(id),
                                      child: IllustCard(
                                        entity: list[index].entity,
                                        heroScope: 'watchlater',
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
