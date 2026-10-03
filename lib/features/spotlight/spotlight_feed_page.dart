import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/press_scale.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/network/api_error.dart';
import '../../core/spotlight/spotlight_feed_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_segmented_button.dart';

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
            padding: const EdgeInsets.only(bottom: FuncSpacing.sm),
            child: AppSegmentedButton<SpotlightCategory>(
              segments: [
                for (final category in SpotlightCategory.values)
                  AppSegment(
                    value: category,
                    label: l10nLookup(context.l10n, category.labelKey),
                  ),
              ],
              selected: _category,
              onSelected: (category) => setState(() => _category = category),
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
                        padding: const EdgeInsets.fromLTRB(
                          FuncSpacing.md,
                          FuncSpacing.sm,
                          FuncSpacing.md,
                          0,
                        ),
                        sliver: SliverList.separated(
                          itemCount: articles.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: FuncSpacing.sm),
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

  static const double _thumbnailWidth = 88;
  static const double _thumbnailHeight = 66;

  final SpotlightArticle article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PressScale(
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openSpotlightArticle(
            context,
            articleId: article.id,
            articleUrl: article.articleUrl,
          ),
          child: Padding(
            padding: const EdgeInsets.all(FuncSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (article.thumbnailUrl != null)
                  ClipRRect(
                    borderRadius: FuncShape.control,
                    // App API thumbnails live on i.pximg.net, which refuses
                    // requests without the Pixiv referer.
                    child: PixivImage.feed(
                      article.thumbnailUrl!,
                      layoutWidth: _thumbnailWidth,
                      width: _thumbnailWidth,
                      height: _thumbnailHeight,
                    ),
                  ),
                if (article.thumbnailUrl != null)
                  const SizedBox(width: FuncSpacing.md),
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
                      const SizedBox(height: FuncSpacing.xs),
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
                            const SizedBox(width: FuncSpacing.sm),
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
      ),
    );
  }
}
