import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/network/api_error.dart';
import '../../core/spotlight/spotlight_feed_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

/// pixivision spotlight article list: a category selector (all/illust/
/// manga) over independent paged feeds. Rows open the in-app article page
/// through `openSpotlightArticle`.
class SpotlightFeedPage extends ConsumerStatefulWidget {
  const SpotlightFeedPage({super.key});

  @override
  ConsumerState<SpotlightFeedPage> createState() => _SpotlightFeedPageState();
}

class _SpotlightFeedPageState extends ConsumerState<SpotlightFeedPage> {
  SpotlightCategory _category = SpotlightCategory.all;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(spotlightFeedProvider(_category));
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.spotlightTitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SegmentedButton<SpotlightCategory>(
              segments: [
                for (final category in SpotlightCategory.values)
                  ButtonSegment(
                    value: category,
                    label: Text(l10nLookup(context.l10n, category.labelKey)),
                  ),
              ],
              selected: {_category},
              showSelectedIcon: false,
              onSelectionChanged: (selected) =>
                  setState(() => _category = selected.first),
            ),
          ),
        ),
      ),
      body: async.when(
        loading: () => const FeedLoading(),
        error: (error, _) => FeedError(
          title: context.l10n.spotlightLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(spotlightFeedProvider(_category).notifier)
              .retryInitial(),
        ),
        data: (feed) {
          if (feed.showInitialError) {
            return FeedError(
              title: context.l10n.spotlightLoadFailed,
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(spotlightFeedProvider(_category).notifier)
                  .retryInitial(),
            );
          }
          if (feed.showInitialSpinner) {
            return const FeedLoading();
          }
          final store = ref.watch(spotlightArticleStoreProvider);
          final articles = [
            for (final id in feed.ids)
              if (store[id] != null) store[id]!,
          ];
          return PullToRefresh(
            onRefresh: () =>
                ref.read(spotlightFeedProvider(_category).notifier).refresh(),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                final metrics = notification.metrics;
                if (metrics.maxScrollExtent > 0 &&
                    metrics.pixels >= metrics.maxScrollExtent - 500) {
                  ref
                      .read(spotlightFeedProvider(_category).notifier)
                      .loadMore();
                }
                return false;
              },
              child: SmoothWheelScroll(
                basePhysics: const AlwaysScrollableScrollPhysics(),
                builder: (context, controller, physics) => CustomScrollView(
                  key: PageStorageKey('spotlight-${_category.name}'),
                  physics: physics,
                  restorationId: 'spotlight-${_category.name}',
                  controller: controller,
                  slivers: [
                    if (articles.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: FeedEmpty(
                          icon: Icons.newspaper_outlined,
                          title: context.l10n.spotlightEmpty,
                          retryLabel: context.l10n.retry,
                          onRefresh: () => ref
                              .read(spotlightFeedProvider(_category).notifier)
                              .refresh(),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        sliver: SliverList.separated(
                          itemCount: articles.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) =>
                              _SpotlightArticleTile(article: articles[index]),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: FeedTail(
                        feed: feed,
                        onRetry: () => ref
                            .read(spotlightFeedProvider(_category).notifier)
                            .retryLoadMore(),
                        errorTitle: context.l10n.spotlightLoadMoreFailed,
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

/// One article row: thumbnail, title, publish date and subcategory label.
/// Tapping opens the parsed in-app article page.
class _SpotlightArticleTile extends StatelessWidget {
  const _SpotlightArticleTile({required this.article});

  final SpotlightArticle article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openSpotlightArticle(
          context,
          articleId: article.id,
          articleUrl: article.articleUrl,
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (article.thumbnailUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CachedNetworkImage(
                    imageUrl: article.thumbnailUrl!,
                    width: 88,
                    height: 66,
                    fit: BoxFit.cover,
                  ),
                ),
              if (article.thumbnailUrl != null) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      article.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (article.subcategoryLabel.isNotEmpty)
                          Flexible(
                            child: Text(
                              article.subcategoryLabel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (article.subcategoryLabel.isNotEmpty &&
                            article.publishDate.isNotEmpty)
                          const SizedBox(width: 8),
                        if (article.publishDate.isNotEmpty)
                          Text(
                            article.publishDate,
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
