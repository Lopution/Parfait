import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/layout/card_columns.dart';
import '../../app/layout/deferred_cache_scroll_view.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/app_spinner.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/load_more_listener.dart';
import '../../app/widgets/novel_entry.dart';
import '../../app/widgets/skeleton/list_skeletons.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/entity/stored_entities.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import '../../app/icons/app_icons.dart';

/// The account's bookmarked novels (Pixiv's markers): each row says where
/// its bookmark is, opens there, and removes or puts back the bookmark.
class NovelMarkersPage extends ConsumerWidget {
  const NovelMarkersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(markedNovelsFeedProvider);
    final controller = ref.read(markedNovelsFeedProvider.notifier);
    return Scaffold(
      appBar: AppTopBar(title: Text(l10n.novelMarkers)),
      body: async.when(
        loading: () => NovelListSkeleton(label: l10n.novelLoading),
        error: (error, _) => FeedError(
          title: l10n.novelMarkersLoadFailed,
          error: error,
          retryLabel: l10n.retry,
          onRetry: controller.retryInitial,
        ),
        data: (feed) {
          if (feed.showInitialError) {
            return FeedError(
              title: l10n.novelMarkersLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: l10n.retry,
              onRetry: controller.retryInitial,
            );
          }
          if (feed.showInitialSpinner) {
            return NovelListSkeleton(label: l10n.novelLoading);
          }
          final novels = ref
              .watch(
                novelStoreProvider.select(
                  (store) => StoredEntities(store, feed.ids),
                ),
              )
              .items;
          return PullToRefresh(
            onRefresh: controller.refresh,
            child: LoadMoreListener(
              itemCount: feed.ids.length,
              onLoadMore: controller.loadMore,
              child: SmoothWheelScroll(
                basePhysics: const AlwaysScrollableScrollPhysics(),
                builder: (context, scroll, physics) => DeferredCacheScrollView(
                  controller: scroll,
                  physics: physics,
                  scrollCacheExtent: kFeedCacheExtent,
                  restorationId: 'novel-markers',
                  slivers: [
                    if (novels.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: FeedEmpty(
                          icon: AppIcons.novelMarkers,
                          title: l10n.novelMarkersEmpty,
                        ),
                      )
                    else ...[
                      SliverPadding(
                        padding: const EdgeInsets.only(top: FuncSpacing.xs),
                        sliver: SliverCardList(
                          itemCount: novels.length,
                          firstId: novels.first.id,
                          warmTexts: (context, index) =>
                              NovelEntry.warmTexts(context, novels[index]),
                          items: novels,
                          itemBuilder: (context, index) =>
                              _MarkedNovelRow(novel: novels[index]),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: FeedTail(
                          feed: feed,
                          onRetry: controller.retryLoadMore,
                          errorTitle: l10n.novelMarkersLoadFailed,
                          retryLabel: l10n.retry,
                        ),
                      ),
                    ],
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

/// A bookmarked novel: where its bookmark is above the title, opening
/// there; the trailing button removes the bookmark, then puts it back at
/// the page it was listed at. The row stays until the list refreshes.
class _MarkedNovelRow extends ConsumerWidget {
  const _MarkedNovelRow({required this.novel});

  final NovelEntity novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final id = novel.id;
    final listed = ref.watch(
      markedNovelPagesProvider.select((pages) => pages[id]),
    );
    // The reader may have moved it since the list loaded.
    final current = novel.markerPage;
    final page = current ?? listed;
    final pending = ref.watch(
      novelMarkerWritesProvider.select((pending) => pending.contains(id)),
    );
    Future<void> write(int? next) async {
      final failed = deferErrorSnackBar(
        context,
        action: l10n.novelMarkerFailed,
      );
      try {
        await ref.read(novelMarkerWritesProvider.notifier).write(id, next);
      } on Object catch (error, stack) {
        failed(error, stack);
      }
    }

    final Widget toggle = pending
        ? const SizedBox.square(
            dimension: kMinInteractiveDimension,
            child: Center(child: AppSpinner(size: 18, strokeWidth: 2)),
          )
        : IconButton(
            tooltip: current == null
                ? l10n.novelMarkerRestore
                : l10n.novelMarkerDelete,
            isSelected: current != null,
            icon: const Icon(AppIcons.watchLater),
            selectedIcon: const Icon(AppIcons.watchLaterFilled),
            onPressed: page == null
                ? null
                : () => unawaited(write(current == null ? page : null)),
          );
    return NovelEntry.regular(
      entity: novel,
      overline: page == null ? null : l10n.novelMarkerAtPage(page),
      trailing: toggle,
      onTap: () => unawaited(openNovel(context, id, atPixivPage: page)),
    );
  }
}
