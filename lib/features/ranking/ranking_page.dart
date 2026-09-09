import 'package:material_ui/material_ui.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../core/entity/illust_store.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/network/api_error.dart';

import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/illust/ranking_feed_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

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
              Tab(text: l10nLookupFor(language.locale, item.labelKey)),
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
      error: (error, _) => FeedError(
        title: l10nLookup(context.l10n, 'rankingLoadFailed'),
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref
            .read(rankingFeedControllerProvider(mode).notifier)
            .retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: l10nLookup(context.l10n, 'rankingLoadFailed'),
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(rankingFeedControllerProvider(mode).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const Center(child: CircularProgressIndicator());
        }
        if (feed.isEmptyAndReady) {
          return ReplicaEmptyState(
            message: context.l10n.rankingEmpty,
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(rankingFeedControllerProvider(mode).notifier)
                .refresh(),
          );
        }

        final entities = store.getAll(feed.ids);
        return PullToRefresh(
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
                IllustFeedGrid(
  padding: const EdgeInsets.symmetric(horizontal: 10),
  mainAxisSpacing: 5,
  crossAxisSpacing: 10,
  itemCount: entities.length,
  itemBuilder: (context, index) => IllustCard(
                      entity: entities[index],
                      heroScope: 'ranking:${mode.name}',
                    ),
),
                SliverToBoxAdapter(
                  child: FeedTail(
                    feed: feed,
                    onRetry: () => ref
                        .read(rankingFeedControllerProvider(mode).notifier)
                        .retryLoadMore(),
                    errorTitle: context.l10n.rankingLoadMoreFailed,
                    retryLabel: context.l10n.retry,
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

