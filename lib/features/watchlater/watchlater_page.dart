import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/feed_entrance.dart';
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
            title: error.toString(),
            error: error,
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
                        itemCount: list.length,
                        itemBuilder: (context, index) => StaggeredEntrance(
                          index: index,
                          child: IllustCard(
                            entity: list[index].entity,
                            heroScope: 'watchlater',
                          ),
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
