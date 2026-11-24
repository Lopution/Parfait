import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/removal.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/page_header.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/auth/account_store.dart';
import '../../core/log.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/series/series_recent_open_store.dart';
import '../../core/watchlist/watchlist_actions.dart';
import '../../core/watchlist/watchlist_feed_controller.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/feed/load_more_listener.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';

/// 追更列表: manga and novel series segments (`/v1/watchlist/*`).
/// A tile shows a "new content" badge while its `latest_content_id` is
/// ahead of the locally stored read cursor.
class WatchlistPage extends StatelessWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppTopBar(
          contentWidth: ContentWidths.management,
          title: Text(context.l10n.watchlistTitle),
          tabsBesideTitle: PageHeader.isWide(context),
          // The feeds sit one Scrollable deep inside the TabBarView's
          // PageView, so their notifications arrive at depth 1.
          notificationPredicate: (notification) => notification.depth == 1,
          bottom: AppTabBar(
            labels: [context.l10n.watchlistManga, context.l10n.watchlistNovel],
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

class _WatchlistFeedBody extends ConsumerStatefulWidget {
  const _WatchlistFeedBody({required this.type});

  final WatchlistType type;

  @override
  ConsumerState<_WatchlistFeedBody> createState() => _WatchlistFeedBodyState();
}

class _WatchlistFeedBodyState extends ConsumerState<_WatchlistFeedBody> {
  final _removals = RemovalController();

  @override
  void dispose() {
    _removals.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final async = ref.watch(watchlistFeedProvider(type));
    // Management-list cap (parent §5.5): left-aligned inside embedded
    // workspaces to follow AppTopBar (PAGE-23), centered standalone.
    return ContentWidthCap(
      maxWidth: ContentWidths.management,
      alignStart: EmbeddedHeaderScope.isActiveOf(context),
      child: async.when(
        loading: () => const FeedLoading(),
        error: (error, _) => FeedError(
          title: context.l10n.watchlistLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () =>
              ref.read(watchlistFeedProvider(type).notifier).refresh(),
        ),
        data: (feed) {
          if (feed.entries.isEmpty) {
            return FeedEmpty(
              icon: AppIcons.watchlist,
              title: context.l10n.watchlistEmpty,
            );
          }
          return PullToRefresh(
            onRefresh: () =>
                ref.read(watchlistFeedProvider(type).notifier).refresh(),
            child: LoadMoreListener(
              itemCount: feed.entries.length,
              onLoadMore: () =>
                  ref.read(watchlistFeedProvider(type).notifier).loadMore(),
              child: RemovalScope(
                controller: _removals,
                child: SmoothWheelScroll(
                  builder: (context, controller, physics) => ListView.builder(
                    controller: controller,
                    physics: physics,
                    itemCount: feed.entries.length + 1,
                    itemBuilder: (context, index) {
                      if (index == feed.entries.length) {
                        return _LoadMoreFooter(
                          feed: feed,
                          onRetry: () => ref
                              .read(watchlistFeedProvider(type).notifier)
                              .retryLoadMore(),
                        );
                      }
                      final entry = feed.entries[index];
                      return Removable(
                        id: entry.key,
                        style: RemovalStyle.row,
                        child: _WatchlistEntryTile(
                          entry: entry,
                          removals: _removals,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({required this.feed, required this.onRetry});

  final WatchlistFeedState feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final loadMoreError = feed.loadMoreError;
    final tailState = PagedFeedState(
      initialPhase: FeedPhase.idle,
      loadMorePhase: feed.loadingMore
          ? FeedPhase.loading
          : loadMoreError != null
          ? FeedPhase.error
          : FeedPhase.idle,
      loadMoreError: loadMoreError == null
          ? null
          : loadMoreError is ApiError
          ? loadMoreError
          : ApiParseError(loadMoreError),
    );
    return FeedTail(
      feed: tailState,
      errorTitle: context.l10n.watchlistLoadMoreFailed,
      retryLabel: context.l10n.retry,
      onRetry: onRetry,
    );
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
  const _WatchlistEntryTile({required this.entry, required this.removals});

  final WatchlistSeriesEntry entry;
  final RemovalController removals;

  static const _coverSize = Size(84, 112);

  /// Inset of the work-count badge on the cover.
  static const double _badgeInset = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seenAsync = ref.watch(_watchlistSeenProvider(entry.key));
    final latest = entry.latestContentId;
    final hasNew =
        latest != null &&
        seenAsync.maybeWhen(
          data: (seen) => seen == null || latest > seen,
          orElse: () => false,
        );
    final published = DateTime.tryParse(
      entry.lastPublishedContentDatetime ?? '',
    );
    final count = entry.publishedContentCount;
    // A large portrait cover, as on a bookshelf: the series is recognised
    // by its cover first, its title second.
    return EntityRow(
      // The menu button's glyph ends on the margin (LAYOUT-15).
      padding: const EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg - EdgeIconButtons.glyphInset,
        FuncSpacing.sm,
      ),
      leading: ClipRRect(
        borderRadius: FuncShape.control,
        child: SizedBox.fromSize(
          size: _coverSize,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (entry.coverUrl != null)
                PixivImage.feed(entry.coverUrl!, layoutWidth: _coverSize.width)
              else
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                ),
              if (count != null)
                Positioned(
                  left: _badgeInset,
                  bottom: _badgeInset,
                  child: EntityBadge(
                    icon: AppIcons.series,
                    label: AppFormat.count(context, count),
                    semanticsLabel: context.l10n.seriesWorksCount(count),
                  ),
                ),
            ],
          ),
        ),
      ),
      title: entry.title,
      titleStyle: Theme.of(context).textTheme.titleMedium,
      subtitle: entry.userName,
      meta: published == null ? null : AppFormat.date(context, published),
      badge: hasNew
          ? EntityBadge(label: context.l10n.watchlistNewContent)
          : null,
      semanticLabel: [
        entry.title,
        entry.userName,
        if (count != null) context.l10n.seriesWorksCount(count),
      ].join(', '),
      onTap: () => unawaited(_viewLatest(context, ref)),
      trailing: Builder(
        builder: (buttonContext) => IconButton(
          icon: const Icon(UiIcons.more),
          tooltip: MaterialLocalizations.of(buttonContext).showMenuTooltip,
          onPressed: () => _openActions(buttonContext, ref),
        ),
      ),
    );
  }

  /// Primary action — "view updates": open the newest tracked content and
  /// advance the read cursor. The cursor is an update marker only — it
  /// never backs a "continue reading" affordance.
  Future<void> _viewLatest(BuildContext context, WidgetRef ref) async {
    final latest = entry.latestContentId;
    final accountId = ref.read(accountStoreProvider).value?.usableCurrent?.id;
    if (accountId != null && latest != null) {
      unawaited(
        ref
            .read(watchlistReadCursorProvider)
            .markSeen(accountId, entry.key, latest)
            .catchError((Object error, _) {
              log('series seen cursor not remembered: $error');
            }),
      );
    }
    ref.invalidate(_watchlistSeenProvider(entry.key));
    if (entry.type == WatchlistType.novel) {
      if (latest != null) {
        await openNovel(context, latest);
      } else {
        await openNovelSeries(context, entry.id);
      }
    } else if (latest != null) {
      await openIllust(context, latest);
    } else {
      await openIllustSeries(context, entry.id);
    }
  }

  Future<void> _openActions(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(accountStoreProvider).value?.usableCurrent?.id;
    // 「继续」 opens the work this account opened last in the series: a
    // manga series remembers it for the session, with its episode number,
    // a novel series across restarts, by its novel alone.
    final recent = entry.type == WatchlistType.manga && accountId != null
        ? ref.read(seriesRecentOpenStoreProvider)[SeriesRecentOpenStore.keyFor(
            accountId,
            entry.id,
          )]
        : null;
    final lastNovelId = entry.type == WatchlistType.novel && accountId != null
        ? await ref
              .read(novelSeriesLastReadStoreProvider)
              .read(accountId, entry.id)
              .catchError((Object error, _) {
                log('novel series last read not read: $error');
                return null;
              })
        : null;
    if (!context.mounted) return;
    await showAppAdaptivePopover<void>(
      context: context,
      anchorContext: context,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(AppIcons.series),
                title: Text(sheetContext.l10n.watchlistOpenContents),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    entry.type == WatchlistType.novel
                        ? openNovelSeries(context, entry.id)
                        : openIllustSeries(context, entry.id),
                  );
                },
              ),
              if (recent != null)
                ListTile(
                  leading: const Icon(AppIcons.history),
                  title: Text(
                    recent.contentOrder != null
                        ? sheetContext.l10n.seriesContinueEpisode(
                            recent.contentOrder!,
                          )
                        : sheetContext.l10n.seriesContinue,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(openIllust(context, recent.illustId));
                  },
                ),
              if (lastNovelId != null)
                ListTile(
                  leading: const Icon(AppIcons.history),
                  title: Text(sheetContext.l10n.seriesContinue),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(openNovel(context, lastNovelId));
                  },
                ),
              ListTile(
                leading: const Icon(UiIcons.removeCircle),
                title: Text(sheetContext.l10n.watchlistRemove),
                onTap: () {
                  final reportFailure = deferErrorSnackBar(
                    context,
                    action: context.l10n.watchlistRemove,
                  );
                  Navigator.of(sheetContext).pop();
                  // The container outlives the tile — read once before the
                  // exit animation and network call run.
                  final container = ProviderScope.containerOf(
                    context,
                    listen: false,
                  );
                  unawaited(() async {
                    await removals.playExit([entry.key]);
                    await container
                        .read(watchlistActionsProvider)
                        .toggle(entry.key);
                    final storeEntry = container.read(
                      watchlistStoreProvider,
                    )[entry.key];
                    if (storeEntry?.error case final error?) {
                      removals.restore([entry.key]);
                      reportFailure(error);
                      return;
                    }
                    if (storeEntry?.shown == true) {
                      removals.restore([entry.key]);
                      return;
                    }
                    container
                        .read(watchlistFeedProvider(entry.type).notifier)
                        .removeEntry(entry.key);
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
