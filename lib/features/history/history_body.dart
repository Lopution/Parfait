import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/motion/removal.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/feed/load_more_listener.dart';
import '../../app/widgets/settings/persist_settings.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_feed_controller.dart';
import '../../core/history/history_models.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import 'history_entry.dart';

/// Paged history grid body handling loading, errors, empty/filtered-empty
/// states, load-more tail, and IME tail padding (`LAYOUT-10`).
class HistoryBody extends ConsumerWidget {
  const HistoryBody({
    super.key,
    required this.generation,
    required this.feedQuery,
    required this.managing,
    required this.selectedKeys,
    required this.onToggle,
    required this.onEnterManaging,
    required this.onClearFilter,
  });

  /// Selection state is owned by the page — the AppBar renders the count
  /// and reads the feed's ids for select-all; the body only reports taps.
  final HistoryFeedQuery feedQuery;

  /// The page's body generation; keys the scroll position.
  final int generation;
  final bool managing;
  final Set<int> selectedKeys;
  final void Function(int recordKey, List<int> orderedKeys) onToggle;
  final ValueChanged<int> onEnterManaging;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(historyFeedControllerProvider(feedQuery));
    Widget failed(Object? error) => FeedError(
      title: context.l10n.historyLoadFailed,
      error: error,
      retryLabel: context.l10n.retry,
      onRetry: () => ref
          .read(historyFeedControllerProvider(feedQuery).notifier)
          .retryInitial(),
    );
    return feed.when(
      loading: () => const FeedLoading(),
      error: (error, _) => failed(error),
      data: (state) {
        // A failed first read arrives as data with an error phase.
        if (state.showInitialError) return failed(state.initialError);
        if (state.ids.isEmpty) {
          final l10n = context.l10n;
          if (feedQuery.hasFilter) {
            return FeedEmpty(
              icon: feedQuery.query.isNotEmpty
                  ? AppIcons.searchOff
                  : AppIcons.history,
              title: l10n.historyFilterEmpty,
              actionLabel: l10n.historyClearFilter,
              actionIcon: UiIcons.reset,
              onAction: onClearFilter,
            );
          }
          // With local recording off nothing will show up here: say so and
          // offer the switch instead.
          final recording =
              ref.watch(settingsProvider).value?.enableHistory ?? true;
          return FeedEmpty(
            icon: AppIcons.history,
            title: l10n.historyEmpty,
            detail: recording
                ? null
                : l10n.historyEmptyRecordingOff(l10n.historyRecordLocal),
            actionLabel: recording ? null : l10n.historyTurnOnRecording,
            actionIcon: AppIcons.history,
            onAction: recording
                ? null
                : () => unawaited(
                    persistSettings(
                      context,
                      () => ref
                          .read(settingsProvider.notifier)
                          .setHistoryEnabled(true),
                    ),
                  ),
          );
        }
        final entries = [
          for (final key in state.ids)
            if (_controllerRecord(ref, key) != null)
              (key: key, record: _controllerRecord(ref, key)!),
        ];
        final orderedKeys = [for (final entry in entries) entry.key];
        final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

        return PullToRefresh(
          onRefresh: () => ref
              .read(historyFeedControllerProvider(feedQuery).notifier)
              .refresh(),
          child: LoadMoreListener(
            itemCount: state.ids.length,
            onLoadMore: () => ref
                .read(historyFeedControllerProvider(feedQuery).notifier)
                .loadMore(),
            child: SmoothWheelScroll(
              builder: (context, controller, physics) =>
                  DeferredCacheScrollView(
                    // A new generation or filter starts at the top, not at the
                    // offset kept for the list it replaced.
                    key: PageStorageKey(
                      'history-${feedQuery.accountId}-'
                      '${feedQuery.contentType?.storageValue ?? 'all'}-'
                      '${feedQuery.query}-$generation',
                    ),
                    controller: controller,
                    physics: physics,
                    scrollCacheExtent: kFeedCacheExtent,
                    restorationId: 'history-${feedQuery.accountId}',
                    slivers: [
                      IllustFeedGrid(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.lg - FuncSpacing.xxs,
                          vertical: FuncSpacing.sm,
                        ),
                        mainAxisSpacing: IllustFeedGrid.defaultMainAxisSpacing,
                        itemCount: entries.length,
                        warmTexts: (context, index) {
                          final record = entries[index].record;
                          final entity =
                              record.contentType == HistoryContentType.illust
                              ? ref
                                    .read(illustStoreProvider)
                                    .get(record.contentId)
                              : null;
                          return entity == null
                              ? const []
                              : IllustCard.warmTexts(context, entity);
                        },
                        itemBuilder: (context, index) => Removable(
                          id: entries[index].key,
                          style: RemovalStyle.tile,
                          child: HistoryEntry(
                            record: entries[index].record,
                            recordKey: entries[index].key,
                            managing: managing,
                            selected: selectedKeys.contains(entries[index].key),
                            onToggle: (key) => onToggle(key, orderedKeys),
                            onEnterManaging: onEnterManaging,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: keyboardInset),
                          child: FeedTail(
                            feed: state,
                            errorTitle: context.l10n.historyLoadFailed,
                            retryLabel: context.l10n.retry,
                            onRetry: () => ref
                                .read(
                                  historyFeedControllerProvider(
                                    feedQuery,
                                  ).notifier,
                                )
                                .retryLoadMore(),
                          ),
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        );
      },
    );
  }

  HistoryRecord? _controllerRecord(WidgetRef ref, int key) => ref
      .read(historyFeedControllerProvider(feedQuery).notifier)
      .recordFor(key);
}
