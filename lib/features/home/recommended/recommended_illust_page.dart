import 'package:material_ui/material_ui.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/pull_to_refresh.dart';
import '../../../app/widgets/replica_empty_state.dart';
import '../../../core/entity/illust_store.dart';

import '../../../core/illust/recommended_illust_controller.dart';
import '../../../l10n/context.dart';

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
          return Scaffold(
            body: ReplicaEmptyState(
              message: context.l10n.recommendedEmpty,
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(recommendedIllustControllerProvider.notifier)
                  .refresh(),
            ),
          );
        }
        final entities = store.getAll(feed.ids);
        return Scaffold(
          body: PullToRefresh(
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
                key: const PageStorageKey('recommended-illust'),
                // U1 (R7): this tab is the only one without an AppBar, so
                // on edge-to-edge Android 15+ the top padding is otherwise
                // zero and the feed overlaps the status bar. Only the top
                // safe inset is added — no AppBar — so the immersive feed
                // look is kept. The RefreshIndicator overscroll zone stays
                // above the padding, so pull-to-refresh still triggers.
                restorationId: 'recommended-illust',
                slivers: [
                  IllustFeedGrid(
                    padding: EdgeInsets.fromLTRB(
                      10,
                      MediaQuery.viewPaddingOf(context).top,
                      10,
                      0,
                    ),
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 10,
                    itemCount: entities.length,
                    itemBuilder: (context, index) => IllustCard(
                      entity: entities[index],
                      heroScope: 'recommended:illust',
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTail(
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
            Text(context.l10n.recommendedLoadFailed),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: Text(context.l10n.retry)),
          ],
        ),
      ),
    );
  }
}
