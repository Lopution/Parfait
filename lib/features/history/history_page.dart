import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';

import '../../app/pixiv_image.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/navigation/routes.dart';
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

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  int _clearGeneration = 0;

  @override
  Widget build(BuildContext context) {
    final accountId = ref.watch(historyAccountIdProvider);
    final repository = ref.watch(historyRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.historySettings),
        actions: [
          if (accountId != null)
            IconButton(
              tooltip: context.l10n.historyDeleteAll,
              onPressed: () => _deleteAll(context, repository, accountId),
              icon: const Icon(Icons.delete_forever_outlined),
            ),
        ],
      ),
      body: accountId == null
          ? Center(child: Text(context.l10n.signedOut))
          : _HistoryBody(
              key: ValueKey('$accountId-$_clearGeneration'),
              accountId: accountId,
            ),
    );
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
  const _HistoryBody({super.key, required this.accountId});

  final String accountId;

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
    if (_scrollController.position.extentAfter < 400) {
      unawaited(
        ref
            .read(historyFeedControllerProvider(widget.accountId).notifier)
            .loadMore(),
      );
    }
  }

  Future<void> _delete(HistoryRecord record) async {
    final confirmed = await _confirmDelete(
      context,
      title: context.l10n.historyDelete,
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(historyFeedControllerProvider(widget.accountId).notifier)
          .removeRecord(record);
    } on Object catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(historyFeedControllerProvider(widget.accountId));
    return feed.when(
      loading: () => const Center(child: CircularProgressIndicator()),
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
        final records = [
          for (final key in state.ids)
            if (_controllerRecord(key) != null) _controllerRecord(key)!,
        ];
        return PullToRefresh(
          onRefresh: () => ref
              .read(historyFeedControllerProvider(widget.accountId).notifier)
              .refresh(),
          child: CustomScrollView(
            key: PageStorageKey('history-${widget.accountId}'),
            controller: _scrollController,
            restorationId: 'history-${widget.accountId}',
            slivers: [
              IllustFeedGrid(
                padding: const EdgeInsets.all(10),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                itemCount: records.length,
                itemBuilder: (context, index) => _HistoryEntry(
                  record: records[index],
                  onLongPress: () => _delete(records[index]),
                ),
              ),
              SliverToBoxAdapter(
                child: switch ((
                  state.showLoadMoreSpinner,
                  state.loadMoreError,
                )) {
                  (true, _) => const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
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
        );
      },
    );
  }

  HistoryRecord? _controllerRecord(int key) => ref
      .read(historyFeedControllerProvider(widget.accountId).notifier)
      .recordFor(key);
}

class _HistoryEntry extends ConsumerWidget {
  const _HistoryEntry({required this.record, required this.onLongPress});

  final HistoryRecord record;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: child,
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
  return showModalBottomSheet<bool>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.35,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text(context.l10n.historyDeleteHint),
                const Spacer(),
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
