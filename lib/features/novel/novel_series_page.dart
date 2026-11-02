import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/layout/card_columns.dart';
import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/author_row.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/expandable_text.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/load_more_listener.dart';
import '../../app/widgets/novel_entry.dart';
import '../../app/widgets/skeleton/list_skeletons.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/stored_entities.dart';
import '../../core/log.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/novel_store.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';

/// One novel series (`/v2/novel/series`): a header with the series' facts
/// and reading actions, then its novels in series order, each under its
/// 「第 n 话」. A restricted novel keeps its place and says why it cannot
/// open.
class NovelSeriesFeedPage extends ConsumerWidget {
  const NovelSeriesFeedPage({super.key, required this.seriesId});

  final int seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(novelSeriesFeedProvider(seriesId));
    final controller = ref.read(novelSeriesFeedProvider(seriesId).notifier);
    final info = ref.watch(novelSeriesInfoProvider(seriesId));
    final header = info.header;
    Widget skeleton() =>
        NovelListSkeleton(label: l10n.contentLoading, overline: true);
    return Scaffold(
      appBar: AppTopBar(
        title: Text(
          header?.title ?? l10n.novelSeries,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: async.when(
        loading: skeleton,
        error: (error, _) => FeedError(
          title: l10n.seriesLoadFailed,
          error: error,
          retryLabel: l10n.retry,
          onRetry: controller.retryInitial,
        ),
        data: (feed) {
          if (feed.showInitialError) {
            return FeedError(
              title: l10n.seriesLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: l10n.retry,
              onRetry: controller.retryInitial,
            );
          }
          if (feed.showInitialSpinner) return skeleton();
          // A viewable entry reads the store, which the reader and the
          // bookmark button keep current; a restricted one is its entry,
          // whatever the store kept of it from before.
          final novels = {
            for (final novel
                in ref
                    .watch(
                      novelStoreProvider.select(
                        (store) => StoredEntities(store, feed.ids),
                      ),
                    )
                    .items)
              novel.id: novel,
          };
          final List<Object> rows = [
            for (final id in feed.ids)
              if (info.entries[id] case final entry? when !entry.viewable)
                entry
              else if (novels[id] case final novel?)
                novel
              else
                ?info.entries[id],
          ];
          return PullToRefresh(
            onRefresh: controller.refresh,
            child: LoadMoreListener(
              itemCount: feed.ids.length,
              onLoadMore: controller.loadMore,
              child: SmoothWheelScroll(
                basePhysics: const AlwaysScrollableScrollPhysics(),
                builder: (context, scroll, physics) => DeferredCacheScrollView(
                  key: PageStorageKey('novel-series-$seriesId'),
                  physics: physics,
                  scrollCacheExtent: kFeedCacheExtent,
                  restorationId: 'novel-series-$seriesId',
                  controller: scroll,
                  slivers: [
                    if (header != null)
                      SliverToBoxAdapter(
                        child: _SeriesHeader(series: header, info: info),
                      ),
                    if (rows.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: FeedEmpty(
                          icon: Icons.library_books_outlined,
                          title: l10n.seriesEmpty,
                        ),
                      )
                    else
                      SliverCardList(
                        itemCount: rows.length,
                        items: rows,
                        // Where each row's 「第 n 话」 comes from.
                        itemDeps: info.entries,
                        itemBuilder: (context, index) => switch (rows[index]) {
                          final NovelEntity novel => _NovelRow(
                            novel: novel,
                            order: info.entries[novel.id]?.contentOrder,
                          ),
                          final row => _RestrictedRow(
                            entry: row as NovelSeriesEntry,
                          ),
                        },
                      ),
                    SliverToBoxAdapter(
                      child: FeedTail(
                        feed: feed,
                        onRetry: controller.retryLoadMore,
                        errorTitle: l10n.seriesLoadMoreFailed,
                        retryLabel: l10n.retry,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NovelRow extends StatelessWidget {
  const _NovelRow({required this.novel, required this.order});

  final NovelEntity novel;
  final int? order;

  @override
  Widget build(BuildContext context) {
    final order = this.order;
    return NovelEntry.regular(
      entity: novel,
      overline: order == null ? null : context.l10n.seriesEpisode(order),
      // The page is the series.
      showSeries: false,
    );
  }
}

/// A novel the account cannot read: its place and title, and pixiv's
/// reason in place of the length line. It does not open.
class _RestrictedRow extends StatelessWidget {
  const _RestrictedRow({required this.entry});

  final NovelSeriesEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final order = entry.contentOrder;
    final overline = order == null ? null : l10n.seriesEpisode(order);
    final reason = entry.viewableMessage ?? l10n.novelRestricted;
    return EntityRow(
      key: ValueKey('novel-${entry.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.lg,
        vertical: FuncSpacing.md,
      ),
      // The novel row's cover, without a cover to show.
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 68,
          height: 88,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: const Icon(Icons.lock_outline),
          ),
        ),
      ),
      overline: overline,
      title: entry.title,
      meta: reason,
      semanticLabel: [?overline, entry.title, reason].join(', '),
    );
  }
}

class _SeriesHeader extends ConsumerStatefulWidget {
  const _SeriesHeader({required this.series, required this.info});

  final NovelSeriesPage series;
  final NovelSeriesInfo info;

  @override
  ConsumerState<_SeriesHeader> createState() => _SeriesHeaderState();
}

class _SeriesHeaderState extends ConsumerState<_SeriesHeader> {
  /// The watchlist cursor is written once per page, not on every rebuild.
  bool _seenMarked = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final series = widget.series;
    final detail = series.detail!;
    final user = detail.user;
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    // Opening the series marks the watchlist "new content" cursor at its
    // newest novel, as the manga series page does.
    final latest = detail.latestNovelId;
    if (latest != null && accountId != null && !_seenMarked) {
      _seenMarked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          ref
              .read(watchlistReadCursorProvider)
              .markSeen(
                accountId,
                WatchlistKey(WatchlistType.novel, series.seriesId),
                latest,
              )
              .catchError((Object error, _) {
                log('series seen cursor not remembered: $error');
              }),
        );
      });
    }
    final count = detail.contentCount;
    final facts = [
      if (count != null) l10n.seriesWorksCount(count),
      if (detail.isConcluded) l10n.novelSeriesConcluded,
      if (detail.isOriginal) l10n.novelSeriesOriginal,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (series.title case final title?)
            Text(
              title,
              style: theme.textTheme.titleLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (user != null)
            AuthorRow(
              userId: user.id,
              name: user.name,
              avatarUrl: user.profileImageUrl,
            ),
          if (facts.isNotEmpty) Text(facts, style: theme.textTheme.bodySmall),
          const SizedBox(height: FuncSpacing.md),
          _SeriesActions(series: series, info: widget.info),
          if (detail.caption.isNotEmpty) ...[
            const SizedBox(height: FuncSpacing.sm),
            ExpandableText(
              TextSpan(text: detail.caption),
              maxLines: 3,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// The manga series' action hierarchy: reading is the filled primary,
/// following the outlined secondary beside it. The primary continues at
/// the novel this account last opened in the series, or starts at the
/// first; the other ways in are text buttons below. Opening a novel lands
/// at its saved place.
class _SeriesActions extends ConsumerWidget {
  const _SeriesActions({required this.series, required this.info});

  final NovelSeriesPage series;
  final NovelSeriesInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final detail = series.detail!;
    void open(int novelId) => unawaited(openNovel(context, novelId));
    final last = ref.watch(novelSeriesLastReadProvider(series.seriesId)).value;
    final first = detail.firstNovelId;
    final latest = detail.latestNovelId;
    // The number is known once the novel's entry has loaded.
    final lastOrder = info.entries[last]?.contentOrder;
    final latestOrder = info.entries[latest]?.contentOrder;
    final Widget? primary = last != null
        ? FilledButton.icon(
            key: const ValueKey('novel-series-read'),
            onPressed: () => open(last),
            icon: const Icon(Icons.play_arrow),
            label: Text(
              lastOrder == null
                  ? l10n.seriesContinue
                  : l10n.seriesContinueEpisode(lastOrder),
            ),
          )
        : first != null
        ? FilledButton.icon(
            key: const ValueKey('novel-series-read'),
            onPressed: () => open(first),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.seriesStartReading),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Side by side while both fit whole; a narrow screen or large text
        // stacks them, primary first, rather than cutting a label.
        OverflowBar(
          spacing: FuncSpacing.sm,
          overflowSpacing: FuncSpacing.sm,
          children: [
            ?primary,
            WatchlistToggle(
              seriesKey: WatchlistKey(WatchlistType.novel, series.seriesId),
              detailAdded: series.watchlistAdded,
            ),
          ],
        ),
        OverflowBar(
          spacing: FuncSpacing.sm,
          children: [
            if (last != null && first != null)
              TextButton(
                onPressed: () => open(first),
                child: Text(l10n.seriesStartFromFirst),
              ),
            if (latest != null)
              TextButton(
                key: const ValueKey('novel-series-latest'),
                onPressed: () => open(latest),
                child: Text(
                  latestOrder == null
                      ? l10n.novelSeriesReadLatest
                      : l10n.novelSeriesReadLatestEpisode(latestOrder),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
