import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/auth/account_store.dart';
import '../../core/series/series_recent_open_store.dart';
import '../../core/watchlist/watchlist_actions.dart';
import '../../core/watchlist/watchlist_feed_controller.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';

/// 追更列表: manga and novel series segments (PixEz `/v1/watchlist/*`).
/// A tile shows a "new content" badge while its `latest_content_id` is
/// ahead of the locally stored read cursor.
class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.watchlistTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: context.l10n.watchlistManga),
              Tab(text: context.l10n.watchlistNovel),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _WatchlistFeedBody(type: WatchlistType.manga),
            _WatchlistFeedBody(type: WatchlistType.novel),
          ],
        ),
      ),
    );
  }
}

class _WatchlistFeedBody extends ConsumerWidget {
  const _WatchlistFeedBody({required this.type});

  final WatchlistType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchlistFeedProvider(type));
    return async.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.watchlistLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref.read(watchlistFeedProvider(type).notifier).refresh(),
      ),
      data: (feed) {
        if (feed.entries.isEmpty) {
          return FeedEmpty(
            icon: Icons.collections_bookmark_outlined,
            title: context.l10n.watchlistEmpty,
            retryLabel: context.l10n.retry,
            onRefresh: () =>
                ref.read(watchlistFeedProvider(type).notifier).refresh(),
          );
        }
        return PullToRefresh(
          onRefresh: () =>
              ref.read(watchlistFeedProvider(type).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              final metrics = notification.metrics;
              if (metrics.maxScrollExtent > 0 &&
                  metrics.pixels >= metrics.maxScrollExtent - 400) {
                ref.read(watchlistFeedProvider(type).notifier).loadMore();
              }
              return false;
            },
            child: ListView.builder(
              itemCount: feed.entries.length + 1,
              itemBuilder: (context, index) {
                if (index == feed.entries.length) {
                  return _LoadMoreFooter(feed: feed);
                }
                return _WatchlistEntryTile(entry: feed.entries[index]);
              },
            ),
          ),
        );
      },
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({required this.feed});

  final WatchlistFeedState feed;

  @override
  Widget build(BuildContext context) {
    if (feed.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            '${context.l10n.watchlistLoadMoreFailed}: '
            '${feed.loadMoreError}',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (feed.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return const SizedBox(height: 16);
  }
}

/// The newest `latest_content_id` the user has opened locally, per series.
final _watchlistSeenProvider = FutureProvider.autoDispose
    .family<int?, WatchlistKey>((ref, key) async {
      final accountId = await ref.watch(
        accountStoreProvider.selectAsync((state) => state.usableCurrent?.id),
      );
      if (accountId == null) return null;
      return ref.read(watchlistReadCursorProvider).read(accountId, key);
    });

class _WatchlistEntryTile extends ConsumerWidget {
  const _WatchlistEntryTile({required this.entry});

  final WatchlistSeriesEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final seenAsync = ref.watch(_watchlistSeenProvider(entry.key));
    final latest = entry.latestContentId;
    final hasNew =
        latest != null &&
        seenAsync.maybeWhen(
          data: (seen) => seen == null || latest > seen,
          orElse: () => false,
        );
    final canOpen = entry.type == WatchlistType.manga || latest != null;
    final published = entry.lastPublishedContentDatetime;
    return EntityRow(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: entry.coverUrl != null
            ? PixivImage(
                url: entry.coverUrl!,
                width: 48,
                height: 48,
                memCacheWidth: PixivImage.decodeWidthFor(48),
              )
            : const SizedBox(width: 48, height: 48),
      ),
      title: entry.title,
      meta: [
        entry.userName,
        if (published != null && published.length >= 10)
          published.substring(0, 10),
        if (entry.publishedContentCount != null)
          context.l10n.seriesWorksCount(entry.publishedContentCount!),
      ].join(' · '),
      badge: hasNew
          ? EntityBadge(
              color: theme.colorScheme.error,
              child: Text(
                context.l10n.watchlistNewContent,
                style: theme.textTheme.labelSmall,
              ),
            )
          : null,
      semanticLabel: '${entry.title}, ${entry.userName}',
      onTap: canOpen ? () => unawaited(_viewLatest(context, ref)) : null,
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        tooltip: MaterialLocalizations.of(context).showMenuTooltip,
        onPressed: () => _openActions(context, ref),
      ),
    );
  }

  /// Primary action — "view updates": open the newest tracked content and
  /// advance the read cursor. The cursor is an update marker only — it
  /// never backs a "continue reading" affordance (prd.md R6).
  Future<void> _viewLatest(BuildContext context, WidgetRef ref) async {
    final latest = entry.latestContentId;
    final accountId = ref.read(accountStoreProvider).value?.usableCurrent?.id;
    if (accountId != null && latest != null) {
      unawaited(
        ref
            .read(watchlistReadCursorProvider)
            .markSeen(accountId, entry.key, latest),
      );
    }
    ref.invalidate(_watchlistSeenProvider(entry.key));
    if (entry.type == WatchlistType.novel) {
      await openNovel(context, latest!);
    } else if (latest != null) {
      await openIllust(context, latest);
    } else {
      await openIllustSeries(context, entry.id);
    }
  }

  Future<void> _openActions(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(accountStoreProvider).value?.usableCurrent?.id;
    // 「返回第 n 话」only exists when the session recorded an opened work —
    // novels never have a record (the store keys manga series only), so the
    // item simply does not render for them.
    final recent = entry.type == WatchlistType.manga && accountId != null
        ? ref.read(seriesRecentOpenStoreProvider)[SeriesRecentOpenStore.keyFor(
            accountId,
            entry.id,
          )]
        : null;
    await showAppBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Contents only exist for manga series — D3: no novel series
              // catalog route this round.
              if (entry.type == WatchlistType.manga)
                ListTile(
                  leading: const Icon(Icons.collections_bookmark_outlined),
                  title: Text(sheetContext.l10n.watchlistOpenContents),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(openIllustSeries(context, entry.id));
                  },
                ),
              if (recent != null)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(
                    recent.contentOrder != null
                        ? sheetContext.l10n.seriesBackToEpisode(
                            recent.contentOrder!,
                          )
                        : sheetContext.l10n.seriesBackToLast,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(openIllust(context, recent.illustId));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.bookmark_remove_outlined),
                title: Text(sheetContext.l10n.watchlistRemove),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  // The container outlives the tile — after the feed
                  // invalidation rebuilds the list a defunct WidgetRef
                  // would throw here.
                  final container = ProviderScope.containerOf(
                    context,
                    listen: false,
                  );
                  unawaited(() async {
                    await container
                        .read(watchlistActionsProvider)
                        .toggle(entry.key);
                    container.invalidate(watchlistFeedProvider(entry.type));
                  }());
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
