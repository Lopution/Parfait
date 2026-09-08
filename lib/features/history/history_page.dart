import 'package:flutter/material.dart';

import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_store.dart';
import '../../core/i18n/replica_strings.dart';

String _historyText(BuildContext context, String key) {
  return ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );
}

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
        title: Text(_historyText(context, 'historySettings')),
        actions: [
          if (accountId != null)
            IconButton(
              tooltip: _historyText(context, 'historyDeleteAll'),
              onPressed: () => _deleteAll(context, repository, accountId),
              icon: const Icon(Icons.delete_forever_outlined),
            ),
        ],
      ),
      body: accountId == null
          ? Center(child: Text(_historyText(context, 'signedOut')))
          : _HistoryBody(
              key: ValueKey('$accountId-$_clearGeneration'),
              accountId: accountId,
              repository: repository,
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
      title: _historyText(context, 'historyDeleteAll'),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await repository.clear(accountId);
      if (context.mounted) {
        setState(() => _clearGeneration++);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_historyText(context, 'historyDeleteAll'))),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

class _HistoryBody extends StatefulWidget {
  const _HistoryBody({
    super.key,
    required this.accountId,
    required this.repository,
  });

  final String accountId;
  final HistoryRepository repository;

  @override
  State<_HistoryBody> createState() => _HistoryBodyState();
}

class _HistoryBodyState extends State<_HistoryBody> {
  static const _pageSize = 30;

  final ScrollController _scrollController = ScrollController();
  final List<HistoryRecord> _records = [];
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reload();
  }

  @override
  void didUpdateWidget(covariant _HistoryBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) _reload();
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
    if (_scrollController.position.extentAfter < 400) _loadMore();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _records.clear();
      _hasMore = false;
    });
    try {
      final result = await widget.repository.page(
        accountId: widget.accountId,
        limit: _pageSize,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _records.addAll(result.records);
        _hasMore = result.hasMore;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    _loadingMore = true;
    try {
      final result = await widget.repository.page(
        accountId: widget.accountId,
        offset: _records.length,
        limit: _pageSize,
      );
      // A refresh or account switch can replace the list while this request
      // is in flight. Never append a page belonging to that stale generation
      // to the newly loaded records.
      if (!mounted || generation != _generation) return;
      setState(() {
        _records.addAll(result.records);
        _hasMore = result.hasMore;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = error);
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _delete(HistoryRecord record) async {
    final confirmed = await _confirmDelete(
      context,
      title: _historyText(context, 'historyDelete'),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.delete(
        accountId: widget.accountId,
        contentType: record.contentType,
        contentId: record.contentId,
      );
      if (!mounted) return;
      setState(
        () => _records.removeWhere(
          (item) =>
              item.contentType == record.contentType &&
              item.contentId == record.contentId,
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _records.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _records.isEmpty) {
      return FeedError(
          title: _historyText(context, 'historyLoadFailed'),
          error: _error!,
          retryLabel: _historyText(context, 'retry'),
          onRetry: _reload,
        );
    }
    if (_records.isEmpty) {
      return ReplicaEmptyState(
        message: _historyText(context, 'historyEmpty'),
        retryLabel: _historyText(context, 'retry'),
        onRetry: _reload,
        icon: Icons.history,
      );
    }
    return PullToRefresh(
      onRefresh: _reload,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          IllustFeedGrid(
  padding: const EdgeInsets.all(10),
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  itemCount: _records.length,
  itemBuilder: (context, index) => _HistoryCard(
                record: _records[index],
                onLongPress: () => _delete(_records[index]),
              ),
),
          SliverToBoxAdapter(
            child: _loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _error == null
                ? const SizedBox(height: 16)
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${_historyText(context, 'historyLoadFailed')}: $_error',
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard({required this.record, required this.onLongPress});

  final HistoryRecord record;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final child = switch (record.contentType) {
      HistoryContentType.illust => _IllustHistoryCard(
        record: record,
        entity: ref.watch(illustStoreProvider).get(record.contentId),
      ),
      HistoryContentType.novel => _NovelHistoryCard(
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

class _IllustHistoryCard extends StatelessWidget {
  const _IllustHistoryCard({required this.record, required this.entity});

  final HistoryRecord record;
  final IllustEntity? entity;

  @override
  Widget build(BuildContext context) {
    if (entity != null) {
      return _HistoryCardFrame(
        lastViewedAt: record.lastViewedAt,
        child: _KnownIllustCard(entity: entity!),
      );
    }
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      child: InkWell(
        onTap: () => openIllust(context, record.contentId),
        child: _SnapshotCard(record: record, icon: Icons.image_outlined),
      ),
    );
  }
}

class _KnownIllustCard extends StatelessWidget {
  const _KnownIllustCard({required this.entity});

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
              child: PixivImage(
                url: entity.imageUrls.medium,
                fit: BoxFit.cover,
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

class _NovelHistoryCard extends StatelessWidget {
  const _NovelHistoryCard({required this.record, required this.entity});

  final HistoryRecord record;
  final NovelEntity? entity;

  @override
  Widget build(BuildContext context) {
    final snapshot = entity == null
        ? InkWell(
            onTap: () => openNovel(context, record.contentId),
            child: _SnapshotCard(
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

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({required this.record, required this.icon});

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
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(icon, size: 42),
            )
          : PixivImage(url: record.snapshot.coverUrl!, fit: BoxFit.cover),
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
                Text(_historyText(context, 'historyDeleteHint')),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(sheetContext).pop(false),
                        child: Text(_historyText(context, 'cancel')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(sheetContext).pop(true),
                        child: Text(_historyText(context, 'confirm')),
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
