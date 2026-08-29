import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../app/pixiv_image.dart';
import '../../../app/replica_page_route.dart';
import '../../bookmark/bookmark_switch_button.dart';
import '../../illust/detail/illust_detail_page.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../core/settings/settings_controller.dart';
import 'recommended_repository.dart';

/// Recommended Illust tab: real API feed with initial/refresh/load-more
/// states, card badges matching beta56 IllustPreviewer, and retained state
/// across Home tab switches (IndexedStack keeps this element alive).
class RecommendedIllustPage extends ConsumerWidget {
  const RecommendedIllustPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recommendedIllustControllerProvider);
    final store = ref.watch(illustStoreProvider);

    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        body: _InitialErrorView(
          error: '$error',
          onRetry: () => ref
              .read(recommendedIllustControllerProvider.notifier)
              .retryInitial(),
        ),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return Scaffold(
            body: _InitialErrorView(
              error: '${feed.initialError}',
              onRetry: () => ref
                  .read(recommendedIllustControllerProvider.notifier)
                  .retryInitial(),
            ),
          );
        }
        if (feed.showInitialSpinner) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (feed.isEmptyAndReady) {
          return const Scaffold(body: Center(child: Text('暂无推荐内容')));
        }
        final entities = store.getAll(feed.ids);
        return Scaffold(
          body: RefreshIndicator(
            onRefresh: () => ref
                .read(recommendedIllustControllerProvider.notifier)
                .refresh(),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollEndNotification &&
                    notification.metrics.extentAfter < 400) {
                  ref
                      .read(recommendedIllustControllerProvider.notifier)
                      .loadMore();
                }
                return false;
              },
              child: CustomScrollView(
                // U1 (R7): this tab is the only one without an AppBar, so
                // on edge-to-edge Android 15+ the top padding is otherwise
                // zero and the feed overlaps the status bar. Only the top
                // safe inset is added — no AppBar — so the immersive feed
                // look is kept. The RefreshIndicator overscroll zone stays
                // above the padding, so pull-to-refresh still triggers.
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      10,
                      MediaQuery.viewPaddingOf(context).top,
                      10,
                      0,
                    ),
                    sliver: SliverMasonryGrid.count(
                      crossAxisCount: 2,
                      mainAxisSpacing: 5,
                      crossAxisSpacing: 10,
                      itemBuilder: (context, index) =>
                          IllustCard(entity: entities[index]),
                      childCount: entities.length,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(recommendedIllustControllerProvider.notifier)
                          .retryLoadMore(),
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
}

class _FeedTail extends StatelessWidget {
  const _FeedTail({required this.feed, required this.onRetry});

  final PagedFeedState feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (feed.showLoadMoreSpinner) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (feed.showLoadMoreError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('加载更多失败'),
              Text(
                '${feed.loadMoreError}',
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
              ),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _InitialErrorView extends StatelessWidget {
  const _InitialErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('推荐内容加载失败'),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// Illust preview card replicating beta56 IllustPreviewer semantics:
/// R-18 top-left, ugoira gif bottom-left, page count top-right, AI
/// bottom-right, title (14 bold) + user name (12) beneath the image.
class IllustCard extends ConsumerWidget {
  const IllustCard({super.key, required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final previewQuality = ref.watch(previewQualityProvider);
    final previewUrl = previewQuality
        ? entity.imageUrls.large
        : entity.imageUrls.medium;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Beta56 IllustPreviewer semantics: the preview height follows the
        // original aspect ratio (BoxFit.fitWidth) inside the waterfall flow,
        // so works are never cropped in the feed.
        LayoutBuilder(
          builder: (context, constraints) {
            final previewHeight = entity.width > 0
                ? constraints.maxWidth / entity.width * entity.height
                : constraints.maxWidth;
            return GestureDetector(
              onTap: () => Navigator.of(context).push(
                ReplicaPageRoute<void>(
                  builder: (_) => IllustDetailPage(illustId: entity.id),
                ),
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: previewHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Only the image participates in the detail Hero
                      // flight. Badges belong to the feed viewport; when the
                      // whole Stack was the Hero, the page-count badge was
                      // scaled and left as a large ghost during pop.
                      //
                      // The ClipRRect sits INSIDE the Hero child (R7 U…):
                      // Hero flight renders the raw child, so a clip outside
                      // the Hero only applied after the flight finished —
                      // the image snapped from square to rounded on pop.
                      // Clipping inside keeps the rounded corners during
                      // the whole flight.
                      Hero(
                        tag: 'IllustHero-${entity.id}',
                        child: ClipRRect(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(12),
                          ),
                          child: PixivImage(
                            url: previewUrl,
                            fit: BoxFit.fitWidth,
                          ),
                        ),
                      ),
                      if (entity.isR18)
                        Positioned(
                          left: 7,
                          top: 7,
                          child: Card(
                            color: colorScheme.primary,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              child: Text(
                                'R-18',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      if (entity.isUgoira)
                        Positioned(
                          left: 7,
                          bottom: 7,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              color: const Color(0x99343838),
                            ),
                            child: const Icon(
                              Icons.gif_box_outlined,
                              color: Colors.white,
                              size: 30,
                            ),
                          ),
                        ),
                      if (entity.pageCount > 1)
                        Positioned(
                          right: 7,
                          top: 7,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(7.5),
                              color: const Color(0x99343838),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              child: Text(
                                '${entity.pageCount}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      if (entity.isAi)
                        Positioned(
                          right: 7,
                          bottom: 7,
                          child: Card(
                            color: colorScheme.error,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              child: Text(
                                'AI',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        // Beta56 title row: 10px indent, title/user block, bookmark heart
        // on the right (BookmarkSwitchButton isButton variant).
        Row(
          children: [
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entity.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    entity.user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            BookmarkSwitchButton(illustId: entity.id, title: entity.title),
          ],
        ),
      ],
    );
  }
}
