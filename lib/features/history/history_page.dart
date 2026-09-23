import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';

import '../../app/pixiv_image.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/navigation/routes.dart';
import '../../app/haptics/app_haptics.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_feed_controller.dart';
import '../../core/history/history_repository.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_store.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  int _clearGeneration = 0;

  /// Selection mode is page-local state (design.md §二): nothing outside
  /// this page consumes it, so it never leaves the widget tree.
  bool _managing = false;
  final Set<int> _selected = <int>{};

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
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      // System back exits selection mode instead of popping the page.
      canPop: !_managing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitManaging();
      },
      child: Scaffold(
        appBar: _managing
            ? AppBar(
                backgroundColor: colorScheme.primaryContainer,
                leading: IconButton(
                  tooltip: context.l10n.cancel,
                  icon: const Icon(Icons.close),
                  onPressed: _exitManaging,
                ),
                title: Text(context.l10n.selectedCount(_selected.length)),
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
            : AppBar(
                title: Text(context.l10n.historySettings),
                actions: [
                  if (accountId != null) ...[
                    IconButton(
                      tooltip: context.l10n.manage,
                      onPressed: _enterManaging,
                      icon: const Icon(Icons.checklist_outlined),
                    ),
                    IconButton(
                      tooltip: context.l10n.historyDeleteAll,
                      onPressed: () =>
                          _deleteAll(context, repository, accountId),
                      icon: const Icon(Icons.delete_forever_outlined),
                    ),
                  ],
                ],
              ),
        body: accountId == null
            ? Center(child: Text(context.l10n.signedOut))
            : _HistoryBody(
                key: ValueKey('$accountId-$_clearGeneration'),
                accountId: accountId,
                managing: _managing,
                selectedKeys: _selected,
                onToggle: _toggleSelected,
                onEnterManaging: _enterManaging,
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
    try {
      final controller = ref.read(
        historyFeedControllerProvider(accountId).notifier,
      );
      for (final key in List<int>.of(_selected)) {
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
      if (mounted) {
        showAppSnackBar(context, '$error');
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
        setState(() => _clearGeneration++);
        showAppSnackBar(context, context.l10n.historyDeleteAll);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, '$error');
      }
    }
  }
}

class _HistoryBody extends ConsumerStatefulWidget {
  const _HistoryBody({
    super.key,
    required this.accountId,
    required this.managing,
    required this.selectedKeys,
    required this.onToggle,
    required this.onEnterManaging,
  });

  /// Selection state is owned by the page — the AppBar renders the count
  /// and reads the feed's ids for select-all; the body only reports taps.
  final String accountId;
  final bool managing;
  final Set<int> selectedKeys;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onEnterManaging;

  @override
  ConsumerState<_HistoryBody> createState() => _HistoryBodyState();
}

class _HistoryBodyState extends ConsumerState<_HistoryBody> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter <
        _scrollController.position.viewportDimension * 1.2) {
      unawaited(
        ref
            .read(historyFeedControllerProvider(widget.accountId).notifier)
            .loadMore(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(historyFeedControllerProvider(widget.accountId));
    return feed.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.historyLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref
            .read(historyFeedControllerProvider(widget.accountId).notifier)
            .retryInitial(),
      ),
      data: (state) {
        if (state.ids.isEmpty) {
          return ReplicaEmptyState(
            message: context.l10n.historyEmpty,
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(historyFeedControllerProvider(widget.accountId).notifier)
                .refresh(),
            icon: Icons.history,
          );
        }
        final entries = [
          for (final key in state.ids)
            if (_controllerRecord(key) != null)
              (key: key, record: _controllerRecord(key)!),
        ];

        return PullToRefresh(
          onRefresh: () => ref
              .read(historyFeedControllerProvider(widget.accountId).notifier)
              .refresh(),
          child: SmoothWheelScroll(
            controller: _scrollController,
            builder: (context, controller, physics) => CustomScrollView(
              key: PageStorageKey('history-${widget.accountId}'),
              controller: controller,
              physics: physics,
              scrollCacheExtent: kFeedCacheExtent,
              restorationId: 'history-${widget.accountId}',
              slivers: [
                IllustFeedGrid(
                  padding: const EdgeInsets.all(10),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _HistoryEntry(
                    record: entries[index].record,
                    recordKey: entries[index].key,
                    managing: widget.managing,
                    selected: widget.selectedKeys.contains(entries[index].key),
                    onToggle: widget.onToggle,
                    onEnterManaging: widget.onEnterManaging,
                  ),
                ),
                SliverToBoxAdapter(
                  child: switch ((
                    state.showLoadMoreSpinner,
                    state.loadMoreError,
                  )) {
                    (true, _) => const Padding(
                      padding: EdgeInsets.all(16),
                      child: FeedLoading(),
                    ),
                    (_, final error?) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '${context.l10n.historyLoadFailed}: $error',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    _ => const SizedBox(height: 16),
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  HistoryRecord? _controllerRecord(int key) => ref
      .read(historyFeedControllerProvider(widget.accountId).notifier)
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
    final colorScheme = Theme.of(context).colorScheme;
    final child = switch (record.contentType) {
      HistoryContentType.illust => _IllustHistoryEntry(
        record: record,
        entity: ref.watch(illustStoreProvider).get(record.contentId),
      ),
      HistoryContentType.novel => _NovelHistoryEntry(
        record: record,
        entity: ref.watch(novelStoreProvider)[record.contentId],
      ),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // In selection mode the whole cell is the selection unit (M3: no
      // nested secondary actions) — any press toggles, the card's own
      // navigation is absorbed.
      onTap: managing ? () => onToggle(recordKey) : null,
      onLongPress: managing
          ? () => onToggle(recordKey)
          : () => onEnterManaging(recordKey),
      child: Stack(
        children: [
          AbsorbPointer(absorbing: managing, child: child),
          if (managing)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: selected
                        ? Border.all(color: colorScheme.primary, width: 2)
                        : null,
                    color: selected
                        ? colorScheme.primary.withValues(alpha: 0.14)
                        : null,
                  ),
                ),
              ),
            ),
          if (selected)
            Positioned(
              top: 8,
              right: 8,
              child: IgnorePointer(
                child: Icon(Icons.check_circle, color: colorScheme.primary),
              ),
            ),
        ],
      ),
    );
  }
}

class _IllustHistoryEntry extends StatelessWidget {
  const _IllustHistoryEntry({required this.record, required this.entity});

  final HistoryRecord record;
  final IllustEntity? entity;

  @override
  Widget build(BuildContext context) {
    if (entity != null) {
      return _HistoryCardFrame(
        lastViewedAt: record.lastViewedAt,
        child: _KnownIllustEntry(entity: entity!),
      );
    }
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      child: InkWell(
        onTap: () => openIllust(context, record.contentId),
        child: _SnapshotEntry(record: record, icon: Icons.image_outlined),
      ),
    );
  }
}

class _KnownIllustEntry extends StatelessWidget {
  const _KnownIllustEntry({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    final previewHeight = entity.width > 0
        ? (MediaQuery.sizeOf(context).width - 30) /
              2 /
              entity.width *
              entity.height
        : 140.0;
    return InkWell(
      onTap: () => openIllust(context, entity.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: previewHeight,
              width: double.infinity,
              child: PixivImage.feed(
                entity.imageUrls.medium,
                layoutWidth: MediaQuery.sizeOf(context).width / 2,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
            child: Text(
              entity.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              entity.user.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
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
    final snapshot = entity == null
        ? InkWell(
            onTap: () => openNovel(context, record.contentId),
            child: _SnapshotEntry(
              record: record,
              icon: Icons.menu_book_outlined,
            ),
          )
        : InkWell(
            onTap: () => openNovel(context, record.contentId),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SnapshotCover(record: record, icon: Icons.menu_book_outlined),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                  child: Text(
                    entity!.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                  child: Text(
                    entity!.user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      child: snapshot,
    );
  }
}

class _HistoryCardFrame extends StatelessWidget {
  const _HistoryCardFrame({required this.lastViewedAt, required this.child});

  final DateTime lastViewedAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            child: Text(
              _formatHistoryDate(lastViewedAt),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
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
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
          child: Text(
            record.snapshot.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
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
      child: record.snapshot.coverUrl == null
          ? ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: Icon(icon, size: 42),
            )
          : PixivImage.feed(
              record.snapshot.coverUrl!,
              layoutWidth: MediaQuery.sizeOf(context).width / 2,
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
          padding: const EdgeInsets.all(20),
          child: Column(
            // Wraps content: a fixed fraction of the sheet height overflowed
            // on short surfaces and left the buttons partially unhit-testable.
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text(context.l10n.historyDeleteHint),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: Text(context.l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
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

String _formatHistoryDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
