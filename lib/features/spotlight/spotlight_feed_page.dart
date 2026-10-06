import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/spotlight_article_card.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../core/network/api_error.dart';
import '../../core/spotlight/spotlight_feed_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// pixivision spotlight article list: category tabs (all/illust/manga) over
/// independent paged feeds. Cards open the in-app article page through
/// `openSpotlightArticle`.
class SpotlightFeedPage extends StatefulWidget {
  const SpotlightFeedPage({super.key});

  @override
  State<SpotlightFeedPage> createState() => _SpotlightFeedPageState();
}

class _SpotlightFeedPageState extends State<SpotlightFeedPage>
    with SingleTickerProviderStateMixin {
  static const _categories = SpotlightCategory.values;

  late final TabController _tabController;
  final _scrollControllers = <SpotlightCategory, ScrollController>{};
  final _loaded = <SpotlightCategory>{SpotlightCategory.all};

  /// A context inside the Scaffold's notification scope (see
  /// [announceTabScroll]).
  late BuildContext _notificationContext;

  SpotlightCategory get _active => _categories[_tabController.index];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _categories.length, vsync: this)
      ..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  ScrollController _scrollControllerFor(SpotlightCategory category) =>
      _scrollControllers.putIfAbsent(
        category,
        () => ScrollController(
          onAttach: (_) {
            // A first-visited tab mounts after the switch announcement.
            if (category == _active) {
              announceTabScroll(
                _notificationContext,
                _scrollControllers[category]!,
              );
            }
          },
        ),
      );

  void _onTabChanged() {
    final category = _active;
    if (!_loaded.contains(category)) {
      setState(() => _loaded.add(category));
    }
    announceTabScroll(_notificationContext, _scrollControllerFor(category));
  }

  void _prepareAdjacent(int index) {
    final neighbours = {
      for (final i in [index - 1, index + 1])
        if (i >= 0 && i < _categories.length) _categories[i],
    };
    if (_loaded.containsAll(neighbours)) return;
    setState(() => _loaded.addAll(neighbours));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopBar(
        title: Text(context.l10n.spotlightTitle),
        bottom: AppTabBar(
          controller: _tabController,
          labels: [
            for (final category in _categories)
              l10nLookup(context.l10n, category.labelKey),
          ],
        ),
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          return TabSwipeSwitcher(
            tabController: _tabController,
            onPrepareAdjacent: _prepareAdjacent,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final category in _categories)
                  if (_loaded.contains(category))
                    _SpotlightCategoryFeed(
                      key: ValueKey(category),
                      category: category,
                      scrollController: _scrollControllerFor(category),
                    )
                  else
                    const SizedBox.shrink(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One category's paged list of [SpotlightArticleCard]s.
class _SpotlightCategoryFeed extends ConsumerWidget {
  const _SpotlightCategoryFeed({
    super.key,
    required this.category,
    required this.scrollController,
  });

  /// Cards stop growing here; wider windows centre the column.
  static const double _maxCardWidth = 640;

  final SpotlightCategory category;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = spotlightFeedProvider(category);
    final async = ref.watch(provider);
    return async.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.spotlightLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref.read(provider.notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.spotlightLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref.read(provider.notifier).retryInitial(),
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
          onRefresh: () => ref.read(provider.notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              final metrics = notification.metrics;
              if (metrics.maxScrollExtent > 0 &&
                  metrics.pixels >= metrics.maxScrollExtent - 500) {
                ref.read(provider.notifier).loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey('spotlight-${category.name}'),
                physics: physics,
                restorationId: 'spotlight-${category.name}',
                controller: controller,
                slivers: [
                  if (articles.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: FeedEmpty(
                        icon: Icons.newspaper_outlined,
                        title: context.l10n.spotlightEmpty,
                        retryLabel: context.l10n.retry,
                        onRefresh: () => ref.read(provider.notifier).refresh(),
                      ),
                    )
                  else
                    SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final cardWidth = math.min(
                          _maxCardWidth,
                          constraints.crossAxisExtent - 2 * FuncSpacing.md,
                        );
                        final side =
                            (constraints.crossAxisExtent - cardWidth) / 2;
                        return SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            side,
                            FuncSpacing.md,
                            side,
                            0,
                          ),
                          sliver: SliverList.separated(
                            itemCount: articles.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: FuncSpacing.md),
                            itemBuilder: (context, index) =>
                                SpotlightArticleCard(
                                  article: articles[index],
                                  imageWidth: cardWidth,
                                ),
                          ),
                        );
                      },
                    ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () =>
                          ref.read(provider.notifier).retryLoadMore(),
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
    );
  }
}
