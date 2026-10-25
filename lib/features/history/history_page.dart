import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';

import '../../app/pixiv_image.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/press_scale.dart';
import '../../app/motion/removal.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/navigation/routes.dart';
import '../../app/haptics/app_haptics.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/selectable_tile.dart';
import '../../app/widgets/selection_app_bar.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/errors/error_category.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_feed_controller.dart';
import '../../core/history/history_repository.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_store.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/settings/persist_settings.dart';
import '../../app/widgets/feed/load_more_listener.dart';

/// The three rows of the history page's overflow menu.
enum _HistoryMenuAction { recordLocal, recordPixiv, deleteAll }

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  /// Bumped by a clear and by an out-of-sight catch-up: the body is built
  /// afresh, its scroll back at the top.
  int _bodyGeneration = 0;

  StreamSubscription<void>? _changes;
  ValueListenable<TickerModeData>? _tickerMode;
  ModalRoute<dynamic>? _route;
  bool _catchingUp = false;
  bool _catchUpAgain = false;

  /// Selection mode is page-local state: nothing outside
  /// this page consumes it, so it never leaves the widget tree.
  bool _managing = false;
  final Set<int> _selected = <int>{};
  final _removals = RemovalController();

  @override
  void initState() {
    super.initState();
    _changes = ref
        .read(historyRepositoryProvider)
        .changes
        .listen((_) => _onHistoryChanged());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.getValuesNotifier(context);
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// The page keeps its order while it shows, and under a page it opened:
  /// the image flying back lands on the card it left. Hidden on another
  /// tab with nothing over it, it catches up out of sight, so the tab
  /// comes back current.
  void _onHistoryChanged() {
    final accountId = ref.read(historyAccountIdProvider);
    if (!mounted ||
        accountId == null ||
        _managing ||
        (_tickerMode?.value.enabled ?? true) ||
        !(_route?.isCurrent ?? false)) {
      return;
    }
    unawaited(_catchUp(accountId));
  }

  Future<void> _catchUp(String accountId) async {
    if (_catchingUp) {
      _catchUpAgain = true;
      return;
    }
    _catchingUp = true;
    try {
      final provider = historyFeedControllerProvider(accountId);
      do {
        _catchUpAgain = false;
        if (!ref.read(provider).hasValue) return;
        await ref.read(provider.notifier).refresh();
      } while (_catchUpAgain && mounted);
      if (mounted) setState(() => _bodyGeneration++);
    } finally {
      _catchingUp = false;
    }
  }

  void _enterManaging([int? recordKey]) {
    // Entering management mode is the explicit-vibration role (W4).
    AppHaptics.confirm();
    setState(() {
      _managing = true;
      if (recordKey != null) _selected.add(recordKey);
    });
  }

  void _toggleSelected(int recordKey) {
    AppHaptics.select();
    setState(() {
      if (!_selected.remove(recordKey)) _selected.add(recordKey);
    });
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selected.clear();
    });
  }

  bool _hasRecords(String accountId) => ref.watch(
    historyFeedControllerProvider(
      accountId,
    ).select((async) => async.value?.ids.isNotEmpty ?? false),
  );

  void _selectAll(String accountId) {
    AppHaptics.select();
    final ids = ref.read(historyFeedControllerProvider(accountId)).value?.ids;
    if (ids == null || ids.isEmpty) return;
    setState(() => _selected.addAll(ids));
  }

  @override
  Widget build(BuildContext context) {
    final accountId = ref.watch(historyAccountIdProvider);
    final repository = ref.watch(historyRepositoryProvider);
    final settings = ref.watch(settingsProvider).value;
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
                    tooltip: context.l10n.selectAll,
                    onPressed: accountId == null
                        ? null
                        : () => _selectAll(accountId),
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    tooltip: context.l10n.historyDelete,
                    onPressed: _selected.isEmpty || accountId == null
                        ? null
                        : () => _deleteSelected(repository, accountId),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              )
            : AppTopBar(
                title: Text(context.l10n.historySettings),
                actions: [
                  // Spelled out like every list's manage entry: an icon
                  // alone did not read as "manage".
                  if (accountId != null)
                    TextButton(
                      // Nothing to manage in an empty history (L1).
                      onPressed: _hasRecords(accountId) ? _enterManaging : null,
                      child: Text(context.l10n.manage),
                    ),
                  // The overflow stays visible signed out: the record
                  // switches are global settings; only delete-all needs
                  // an account.
                  AppMenuButton<_HistoryMenuAction>(
                    onSelected: (menuContext, action) => _onMenuAction(
                      menuContext,
                      action,
                      repository,
                      accountId,
                    ),
                    entries: [
                      AppMenuEntry(
                        value: _HistoryMenuAction.recordLocal,
                        label: context.l10n.historyRecordLocal,
                        checked: settings?.enableHistory ?? false,
                        enabled: settings != null,
                      ),
                      AppMenuEntry(
                        value: _HistoryMenuAction.recordPixiv,
                        label: context.l10n.historyRecordPixiv,
                        checked: settings?.enablePixivHistory ?? false,
                        enabled: settings != null,
                      ),
                      AppMenuEntry(
                        value: _HistoryMenuAction.deleteAll,
                        label: context.l10n.historyDeleteAll,
                        enabled: accountId != null,
                      ),
                    ],
                  ),
                ],
              ),
        body: accountId == null
            ? Center(child: Text(context.l10n.signedOut))
            : RemovalScope(
                controller: _removals,
                child: _HistoryBody(
                  key: ValueKey('$accountId-$_bodyGeneration'),
                  generation: _bodyGeneration,
                  accountId: accountId,
                  managing: _managing,
                  selectedKeys: _selected,
                  onToggle: _toggleSelected,
                  onEnterManaging: _enterManaging,
                ),
              ),
      ),
    );
  }

  Future<void> _deleteSelected(
    HistoryRepository repository,
    String accountId,
  ) async {
    // Opening the destructive confirm surface is the explicit-vibration
    // role; the row-level toggles stay on the light tick.
    AppHaptics.confirm();
    final confirmed = await _confirmDelete(
      context,
      title: context.l10n.historyDelete,
    );
    if (confirmed != true || !mounted) return;
    final keys = List<int>.of(_selected);
    final controller = ref.read(
      historyFeedControllerProvider(accountId).notifier,
    );
    // The tiles leave first; the delete then drops them from the feed.
    await _removals.playExit(keys);
    try {
      for (final key in keys) {
        final record = controller.recordFor(key);
        if (record != null) await controller.removeRecord(record);
      }
      if (mounted) {
        setState(() {
          _managing = false;
          _selected.clear();
        });
      }
    } on Object catch (error) {
      _removals.restore(keys);
      if (mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.historyDelete,
          error: error,
        );
      }
    }
  }

  void _onMenuAction(
    BuildContext menuContext,
    _HistoryMenuAction action,
    HistoryRepository repository,
    String? accountId,
  ) {
    final notifier = ref.read(settingsProvider.notifier);
    final settings = ref.read(settingsProvider).value;
    switch (action) {
      case _HistoryMenuAction.recordLocal:
        if (settings == null) return;
        unawaited(
          persistSettings(
            menuContext,
            () => notifier.setHistoryEnabled(!settings.enableHistory),
          ),
        );
      case _HistoryMenuAction.recordPixiv:
        if (settings == null) return;
        unawaited(
          persistSettings(
            menuContext,
            () => notifier.setPixivHistoryEnabled(!settings.enablePixivHistory),
          ),
        );
      case _HistoryMenuAction.deleteAll:
        if (accountId != null) {
          unawaited(_deleteAll(menuContext, repository, accountId));
        }
    }
  }

  Future<void> _deleteAll(
    BuildContext context,
    HistoryRepository repository,
    String accountId,
  ) async {
    final confirmed = await _confirmDelete(
      context,
      title: context.l10n.historyDeleteAll,
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await repository.clear(accountId);
      if (context.mounted) {
        setState(() => _bodyGeneration++);
        showAppSnackBar(context, context.l10n.historyDeleteAll);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.historyDeleteAll,
          error: error,
        );
      }
    }
  }
}

class _HistoryBody extends ConsumerWidget {
  const _HistoryBody({
    super.key,
    required this.generation,
    required this.accountId,
    required this.managing,
    required this.selectedKeys,
    required this.onToggle,
    required this.onEnterManaging,
  });

  /// Selection state is owned by the page — the AppBar renders the count
  /// and reads the feed's ids for select-all; the body only reports taps.
  final String accountId;

  /// The page's body generation; keys the scroll position.
  final int generation;
  final bool managing;
  final Set<int> selectedKeys;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onEnterManaging;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(historyFeedControllerProvider(accountId));
    return feed.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.historyLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref
            .read(historyFeedControllerProvider(accountId).notifier)
            .retryInitial(),
      ),
      data: (state) {
        if (state.ids.isEmpty) {
          // With local recording off nothing will show up here: say so and
          // offer the switch instead.
          final l10n = context.l10n;
          final recording =
              ref.watch(settingsProvider).value?.enableHistory ?? true;
          return FeedEmpty(
            icon: Icons.history,
            title: l10n.historyEmpty,
            detail: recording
                ? null
                : l10n.historyEmptyRecordingOff(l10n.historyRecordLocal),
            actionLabel: recording ? null : l10n.historyTurnOnRecording,
            actionIcon: Icons.history,
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

        return PullToRefresh(
          onRefresh: () => ref
              .read(historyFeedControllerProvider(accountId).notifier)
              .refresh(),
          child: LoadMoreListener(
            itemCount: state.ids.length,
            onLoadMore: () => ref
                .read(historyFeedControllerProvider(accountId).notifier)
                .loadMore(),
            child: SmoothWheelScroll(
              builder: (context, controller, physics) =>
                  DeferredCacheScrollView(
                    // A new generation starts at the top, not at the
                    // offset kept for the list it replaced.
                    key: PageStorageKey('history-$accountId-$generation'),
                    controller: controller,
                    physics: physics,
                    scrollCacheExtent: kFeedCacheExtent,
                    restorationId: 'history-$accountId',
                    slivers: [
                      IllustFeedGrid(
                        padding: const EdgeInsets.all(FuncSpacing.sm),
                        mainAxisSpacing: FuncSpacing.sm,
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
                          child: _HistoryEntry(
                            record: entries[index].record,
                            recordKey: entries[index].key,
                            managing: managing,
                            selected: selectedKeys.contains(entries[index].key),
                            onToggle: onToggle,
                            onEnterManaging: onEnterManaging,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: switch ((
                          state.showLoadMoreSpinner,
                          state.loadMoreError,
                        )) {
                          (true, _) => const Padding(
                            padding: EdgeInsets.all(FuncSpacing.lg),
                            child: FeedLoading(),
                          ),
                          (_, final error?) => Padding(
                            padding: const EdgeInsets.all(FuncSpacing.lg),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  context.l10n.historyLoadFailed,
                                  textAlign: TextAlign.center,
                                ),
                                Text(
                                  errorCategoryText(
                                    context,
                                    categorizeError(error),
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                                ErrorDetails(error: error),
                              ],
                            ),
                          ),
                          _ => const SizedBox(height: FuncSpacing.lg),
                        },
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
      .read(historyFeedControllerProvider(accountId).notifier)
      .recordFor(key);
}

class _HistoryEntry extends ConsumerWidget {
  const _HistoryEntry({
    required this.record,
    required this.recordKey,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.onEnterManaging,
  });

  final HistoryRecord record;

  /// The encoded feed key (content type in the high bits) — selection
  /// tracks records by it, so an illust and a novel sharing a numeric id
  /// never collide.
  final int recordKey;
  final bool managing;
  final bool selected;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onEnterManaging;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Known-illust cells render the shared IllustCard; its own long-press
    // would open the card action sheet, but in history the gesture is the
    // selection-mode entry/toggle, so the page
    // supplies the callback.
    final longPress = managing
        ? () => onToggle(recordKey)
        : () => onEnterManaging(recordKey);
    final child = switch (record.contentType) {
      HistoryContentType.illust => _IllustHistoryEntry(
        record: record,
        entity: ref.watch(illustStoreProvider).get(record.contentId),
        onLongPress: longPress,
      ),
      HistoryContentType.novel => _NovelHistoryEntry(
        record: record,
        entity: ref.watch(
          novelStoreProvider.select((store) => store[record.contentId]),
        ),
      ),
    };
    return SelectableTile(
      managing: managing,
      selected: selected,
      onToggle: () => onToggle(recordKey),
      onLongPress: longPress,
      child: child,
    );
  }
}

/// The history page's own Hero scope (TRANS-07): a work seen lately is
/// often on a feed still mounted in another branch.
const _heroScope = 'history';

class _IllustHistoryEntry extends StatelessWidget {
  const _IllustHistoryEntry({
    required this.record,
    required this.entity,
    required this.onLongPress,
  });

  final HistoryRecord record;
  final IllustEntity? entity;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final entity = this.entity;
    if (entity != null) {
      // Shared object contract: the card consumes FeedItemExtent for its
      // preview height and carries the visit date in the meta slot.
      return IllustCard(
        entity: entity,
        heroScope: _heroScope,
        meta: EntityMetaText(AppFormat.relative(context, record.lastViewedAt)),
        onLongPress: onLongPress,
      );
    }
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      child: InkWell(
        onTap: () =>
            openIllust(context, record.contentId, heroScope: _heroScope),
        child: _SnapshotEntry(record: record, icon: Icons.image_outlined),
      ),
    );
  }
}

class _NovelHistoryEntry extends StatelessWidget {
  const _NovelHistoryEntry({required this.record, required this.entity});

  final HistoryRecord record;
  final NovelEntity? entity;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = entity?.title ?? record.snapshot.title;
    final author = entity?.user.name ?? record.snapshot.authorName;
    final coverUrl = entity?.coverImageUrl ?? record.snapshot.coverUrl;
    void open() => openNovel(context, record.contentId);
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      // The square cell follows the object contract: PressScale feedback,
      // an explicit Semantics label, rounded cover and a type badge so
      // novels stay distinguishable in the mixed history grid.
      child: PressScale(
        child: Semantics(
          container: true,
          button: true,
          image: true,
          label: '$title, $author',
          onTap: open,
          child: GestureDetector(
            excludeFromSemantics: true,
            onTap: open,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: FuncShape.card,
                        child: coverUrl == null
                            ? ColoredBox(
                                color: colorScheme.surfaceContainer,
                                child: const Icon(
                                  Icons.menu_book_outlined,
                                  size: 42,
                                ),
                              )
                            : PixivImage.feed(
                                coverUrl,
                                layoutWidth:
                                    MediaQuery.sizeOf(context).width / 2,
                              ),
                      ),
                    ),
                    const Positioned(
                      left: 7,
                      top: 7,
                      child: EntityBadge(icon: Icons.menu_book_outlined),
                    ),
                  ],
                ),
                Padding(
                  padding: _titlePadding,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: _linePadding,
                  child: Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A history cell's title, under the cover.
const _titlePadding = EdgeInsets.fromLTRB(
  IllustCard.textIndent,
  FuncSpacing.sm,
  IllustCard.textIndent,
  0,
);

/// A history cell's author and date lines.
const _linePadding = EdgeInsets.symmetric(horizontal: IllustCard.textIndent);

/// A cell drawn here (a novel, a work not in the store) laid out like the
/// shared [IllustCard] beside it: flat, the text on the card's indent.
class _HistoryCardFrame extends StatelessWidget {
  const _HistoryCardFrame({required this.lastViewedAt, required this.child});

  final DateTime lastViewedAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        Padding(
          padding: _linePadding,
          child: EntityMetaText(AppFormat.relative(context, lastViewedAt)),
        ),
      ],
    );
  }
}

class _SnapshotEntry extends StatelessWidget {
  const _SnapshotEntry({required this.record, required this.icon});

  final HistoryRecord record;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SnapshotCover(record: record, icon: icon),
        Padding(
          padding: _titlePadding,
          child: Text(
            record.snapshot.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: _linePadding,
          child: Text(
            record.snapshot.authorName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _SnapshotCover extends StatelessWidget {
  const _SnapshotCover({required this.record, required this.icon});

  final HistoryRecord record;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: FuncShape.card,
        child: record.snapshot.coverUrl == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Icon(icon, size: 42),
              )
            : PixivImage.feed(
                record.snapshot.coverUrl!,
                layoutWidth: MediaQuery.sizeOf(context).width / 2,
              ),
      ),
    );
  }
}

Future<bool?> _confirmDelete(BuildContext context, {required String title}) {
  return showAppBottomSheet<bool>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: Column(
            // Wraps content: a fixed fraction of the sheet height overflowed
            // on short surfaces and left the buttons partially unhit-testable.
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: FuncSpacing.md),
              Text(context.l10n.historyDeleteHint),
              const SizedBox(height: FuncSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: Text(context.l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: Text(context.l10n.confirm),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
