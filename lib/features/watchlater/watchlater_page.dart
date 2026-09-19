import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/watchlater/watch_later_store.dart';
import '../../l10n/context.dart';

/// Local watch-later list: stashed illusts render straight from the stored
/// payload — no network — and long-pressing a card offers "remove" through
/// the same action registry as the feeds.
class WatchLaterPage extends ConsumerWidget {
  const WatchLaterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final entries = ref.watch(watchLaterStoreProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.watchLaterTitle)),
      body: PullToRefresh(
        onRefresh: () => ref.refresh(watchLaterStoreProvider.future),
        child: entries.when(
          loading: () => const Center(child: FeedLoading()),
          error: (error, _) => FeedError(
            title: l10n.watchLaterLoadFailed,
            error: error,
            retryLabel: l10n.retry,
            onRetry: () => ref.invalidate(watchLaterStoreProvider),
          ),
          data: (list) => list.isEmpty
              ? FeedEmpty(
                  icon: Icons.bookmark_border,
                  title: l10n.watchLaterTitle,
                  detail: l10n.watchLaterEmpty,
                )
              : SmoothWheelScroll(
                  builder: (context, controller, physics) => CustomScrollView(
                    controller: controller,
                    physics: physics,
                    scrollCacheExtent: kFeedCacheExtent,
                    restorationId: 'watchlater',
                    slivers: [
                      IllustFeedGrid(
                        padding: const EdgeInsets.all(10),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        itemIds: [for (final e in list) e.entity.id],
                        itemCount: list.length,
                        // IllustFeedGrid already wraps each item in a
                        // StaggeredEntrance — nesting a second one doubled
                        // the opacity/offset on every card.
                        itemBuilder: (context, index) => IllustCard(
                          entity: list[index].entity,
                          heroScope: 'watchlater',
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
