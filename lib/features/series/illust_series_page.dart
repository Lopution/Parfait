import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/format/app_format.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/skeleton/list_skeletons.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/author_row.dart';
import '../../app/widgets/expandable_text.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/series/series_feed_controller.dart';
import '../../core/series/series_models.dart';
import '../../core/series/series_recent_open_store.dart';
import '../../core/series/series_store.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// One illust series: a header (cover/title/author/work count/caption) plus
/// the paginated episode list (`/v1/illust/series`, newest first). Episodes
/// are rows, not a grid: a reader looks for "which episode", so the number
/// and the title lead and the cover only identifies.

class IllustSeriesPage extends ConsumerWidget {
  const IllustSeriesPage({super.key, required this.seriesId});

  final int seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(illustSeriesFeedProvider(seriesId));
    final detail = ref.watch(illustSeriesStoreProvider)[seriesId];
    return Scaffold(
      appBar: AppTopBar(
        title: Text(
          detail?.title ?? context.l10n.seriesTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: async.when(
        loading: () => EpisodeListSkeleton(label: context.l10n.contentLoading),
        error: (error, _) => FeedError(
          title: context.l10n.seriesLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(illustSeriesFeedProvider(seriesId).notifier)
              .retryInitial(),
        ),
        data: (feed) {
          if (feed.showInitialError) {
            return FeedError(
              title: context.l10n.seriesLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(illustSeriesFeedProvider(seriesId).notifier)
                  .retryInitial(),
            );
          }
          if (feed.showInitialSpinner) {
            return EpisodeListSkeleton(label: context.l10n.contentLoading);
          }
          final entities = ref.watch(illustStoreProvider).getAll(feed.ids);
          return PullToRefresh(
            onRefresh: () =>
                ref.read(illustSeriesFeedProvider(seriesId).notifier).refresh(),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                // Same -500px threshold as the detail page's related works:
                // loadMore is internally guarded against re-entry and the
                // exhausted state.
                final metrics = notification.metrics;
                if (metrics.maxScrollExtent > 0 &&
                    metrics.pixels >= metrics.maxScrollExtent - 500) {
                  ref
                      .read(illustSeriesFeedProvider(seriesId).notifier)
                      .loadMore();
                }
                return false;
              },
              child: SmoothWheelScroll(
                basePhysics: const AlwaysScrollableScrollPhysics(),
                builder: (context, controller, physics) => CustomScrollView(
                  key: PageStorageKey('series-$seriesId'),
                  physics: physics,
                  scrollCacheExtent: kFeedCacheExtent,
                  restorationId: 'series-$seriesId',
                  controller: controller,
                  slivers: [
                    if (detail != null)
                      SliverToBoxAdapter(child: _SeriesHeader(detail: detail)),
                    if (entities.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: FeedEmpty(
                          icon: Icons.collections_bookmark_outlined,
                          title: context.l10n.seriesEmpty,
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: entities.length,
                        itemBuilder: (context, index) => _EpisodeRow(
                          entity: entities[index],
                          episode: _episodeNumber(index, entities, detail),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: FeedTail(
                        feed: feed,
                        onRetry: () => ref
                            .read(illustSeriesFeedProvider(seriesId).notifier)
                            .retryLoadMore(),
                        errorTitle: context.l10n.seriesLoadMoreFailed,
                        retryLabel: context.l10n.retry,
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

/// The 1-based episode number of the row at [index]. pixiv sends no
/// per-work order here, so it is counted: from the series' work count down
/// when the list runs newest first (the usual order), from one up when it
/// starts at the first episode. Null when the count is unknown.
int? _episodeNumber(
  int index,
  List<IllustEntity> entities,
  IllustSeriesEntity? detail,
) {
  final first = detail?.firstContentId;
  final ascending = first != null && entities.first.id == first;
  if (ascending) return index + 1;
  final total = detail?.workCount;
  if (total == null || total - index < 1) return null;
  return total - index;
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({required this.entity, required this.episode});

  final IllustEntity entity;
  final int? episode;

  /// Inset of the page-count badge — a fraction of a feed card's 7dp, to
  /// match the smaller cover.
  static const double _badgeInset = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final episode = this.episode;
    final overline = episode == null ? null : l10n.seriesEpisode(episode);
    final created = DateTime.tryParse(entity.createDate ?? '');
    return EntityRow(
      key: ValueKey('series-episode-${entity.id}'),
      padding: episodeRowPadding,
      leading: ClipRRect(
        borderRadius: FuncShape.control,
        child: SizedBox.fromSize(
          size: episodeCoverSize,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PixivImage.feed(
                entity.imageUrls.medium,
                layoutWidth: episodeCoverSize.width,
              ),
              if (entity.pageCount > 1)
                Positioned(
                  left: _badgeInset,
                  bottom: _badgeInset,
                  child: EntityBadge(
                    icon: Icons.photo_library_outlined,
                    label: AppFormat.count(context, entity.pageCount),
                  ),
                ),
            ],
          ),
        ),
      ),
      overline: overline,
      title: entity.title,
      titleStyle: Theme.of(context).textTheme.titleMedium,
      meta: created == null ? null : AppFormat.date(context, created),
      semanticLabel: [
        ?overline,
        entity.title,
        if (entity.pageCount > 1) l10n.illustPagesTotal(entity.pageCount),
      ].join(', '),
      onTap: () => openIllust(context, entity.id, initialEntity: entity),
    );
  }
}

class _SeriesHeader extends ConsumerWidget {
  const _SeriesHeader({required this.detail});

  final IllustSeriesEntity detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cover = detail.coverUrl;
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    // Opening the series marks the watchlist "new content" cursor at the
    // newest work the page knows about.
    final latest = detail.latestContentId;
    if (latest != null && accountId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(watchlistReadCursorProvider)
            .markSeen(
              accountId,
              WatchlistKey(WatchlistType.manga, detail.id),
              latest,
            );
      });
    }
    // 「继续第 n 话」honest variant: only what the session memory recorded —
    // this is a different state source than the markSeen cursor above (W4
    // gate: the two must not share one store).
    final recentOpenMap = ref.watch(seriesRecentOpenStoreProvider);
    final recent = accountId == null
        ? null
        : recentOpenMap[SeriesRecentOpenStore.keyFor(accountId, detail.id)];
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cover != null)
                ClipRRect(
                  borderRadius: FuncShape.control,
                  child: PixivImage(
                    url: cover,
                    width: 88,
                    height: 88,
                    memCacheWidth: PixivImage.decodeWidthFor(88),
                  ),
                ),
              if (cover != null) const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.title,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    AuthorRow(userId: detail.userId, name: detail.userName),
                    if (detail.workCount != null)
                      Text(
                        context.l10n.seriesWorksCount(detail.workCount!),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: FuncSpacing.md),
          _SeriesActions(detail: detail, recent: recent),
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

/// The header's actions on one line, one hierarchy: reading is the filled
/// primary, following the series the outlined secondary beside it at the
/// same height. With a reading record (this
/// session's last opened work) the primary continues there and starting
/// over from the first episode is a text button below; without one the
/// primary starts at the first episode.
class _SeriesActions extends ConsumerWidget {
  const _SeriesActions({required this.detail, required this.recent});

  final IllustSeriesEntity detail;
  final SeriesRecentOpenEntry? recent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    void open(int illustId) => openIllust(
      context,
      illustId,
      initialEntity: ref.read(illustStoreProvider).get(illustId),
    );
    final recent = this.recent;
    // Parsed from `illust_series_first_illust`; null when pixiv omits it.
    final first = detail.firstContentId;
    final order = recent?.contentOrder;
    final Widget? primary = recent != null
        ? FilledButton.icon(
            key: const ValueKey('series-read'),
            onPressed: () => open(recent.illustId),
            icon: const Icon(Icons.play_arrow),
            label: Text(
              order == null
                  ? l10n.seriesContinue
                  : l10n.seriesContinueEpisode(order),
            ),
          )
        : first != null
        ? FilledButton.icon(
            key: const ValueKey('series-read'),
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
              seriesKey: WatchlistKey(WatchlistType.manga, detail.id),
              detailAdded: detail.watchlistAdded,
            ),
          ],
        ),
        if (recent != null && first != null)
          TextButton(
            onPressed: () => open(first),
            child: Text(l10n.seriesStartFromFirst),
          ),
      ],
    );
  }
}
