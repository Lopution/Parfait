import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../core/entity/illust_store.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/network/api_error.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../home/recommended/recommended_illust_page.dart';
import 'ranking_repository.dart';

/// Ranking page with beta56's horizontally scrollable 11-mode tab bar.
/// Only the selected mode is built, while controllers and scroll positions
/// remain cached by the page for tab switching.
class RankingPage extends StatefulWidget {
  const RankingPage({super.key});

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _scrollControllers = <RankingMode, ScrollController>{};
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: RankingMode.values.length,
      vsync: this,
    )..addListener(_handleTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _handleTabChanged() {
    if (_selectedIndex == _tabController.index) return;
    setState(() => _selectedIndex = _tabController.index);
  }

  ScrollController _scrollControllerFor(RankingMode mode) {
    return _scrollControllers.putIfAbsent(mode, ScrollController.new);
  }

  @override
  Widget build(BuildContext context) {
    final language = ReplicaLanguage.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
    );
    final mode = RankingMode.values[_selectedIndex];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: 5),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          tabs: [
            for (final item in RankingMode.values)
              Tab(text: ReplicaStrings.text(language, item.labelKey)),
          ],
        ),
      ),
      body: _RankingModeBody(
        key: ValueKey(mode),
        mode: mode,
        scrollController: _scrollControllerFor(mode),
      ),
    );
  }
}

class _RankingModeBody extends ConsumerWidget {
  const _RankingModeBody({
    super.key,
    required this.mode,
    required this.scrollController,
  });

  final RankingMode mode;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(rankingFeedControllerProvider(mode));
    final store = ref.watch(illustStoreProvider);
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _RankingInitialError(
        mode: mode,
        error: error,
        onRetry: () => ref
            .read(rankingFeedControllerProvider(mode).notifier)
            .retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return _RankingInitialError(
            mode: mode,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            onRetry: () => ref
                .read(rankingFeedControllerProvider(mode).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const Center(child: CircularProgressIndicator());
        }
        if (feed.isEmptyAndReady) {
          return const Center(child: Text('暂无榜单内容'));
        }

        final entities = store.getAll(feed.ids);
        return RefreshIndicator(
          onRefresh: () =>
              ref.read(rankingFeedControllerProvider(mode).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollEndNotification &&
                  notification.metrics.extentAfter < 400) {
                ref
                    .read(rankingFeedControllerProvider(mode).notifier)
                    .loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              controller: scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
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
                  child: _RankingFeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(rankingFeedControllerProvider(mode).notifier)
                        .retryLoadMore(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RankingFeedTail extends StatelessWidget {
  const _RankingFeedTail({required this.feed, required this.onRetry});

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

class _RankingInitialError extends StatelessWidget {
  const _RankingInitialError({
    required this.mode,
    required this.error,
    required this.onRetry,
  });

  final RankingMode mode;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final language = ReplicaLanguage.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text('${ReplicaStrings.text(language, mode.labelKey)}加载失败'),
            const SizedBox(height: 8),
            Text(
              '$error',
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
