import 'package:material_ui/material_ui.dart';

import '../../app/navigation/routes.dart';
import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../core/entity/illust_store.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/network/api_error.dart';

import '../../app/widgets/branch_slide_stack.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/root_swipe_switcher.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/illust/ranking_feed_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';

/// Ranking page with beta56's horizontally scrollable 11-mode tab bar.
/// Only the selected mode is built, while controllers and scroll positions
/// remain cached by the page for tab switching.
class RankingPage extends StatefulWidget {
  const RankingPage({
    super.key,
    this.initialMode = RankingMode.day,
    this.onModeChanged,
  });

  final RankingMode initialMode;
  final ValueChanged<RankingMode>? onModeChanged;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _scrollControllers = <RankingMode, ScrollController>{};
  final _loadedModes = <int>{};
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: RankingMode.values.length,
      vsync: this,
      initialIndex: RankingMode.values.indexOf(widget.initialMode),
    )..addListener(_handleTabChanged);
    _selectedIndex = _tabController.index;
    _loadedModes.add(_selectedIndex);
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
    final mode = RankingMode.values[_tabController.index];
    setState(() {
      _selectedIndex = _tabController.index;
      _loadedModes.add(_selectedIndex);
    });
    widget.onModeChanged?.call(mode);
  }

  ScrollController _scrollControllerFor(RankingMode mode) {
    return _scrollControllers.putIfAbsent(mode, ScrollController.new);
  }

  @override
  Widget build(BuildContext context) {
    final language = ReplicaLanguage.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 0,
        actions: [
          IconButton(
            tooltip: context.l10n.novelRanking,
            onPressed: () => openNovelRanking(context),
            icon: const Icon(Icons.menu_book_outlined),
          ),
        ],
        title: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: 5),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          onTap: (index) {
            // TabBar already ran controller.animateTo before this
            // callback — and TabController._changeIndex early-returns on
            // a same-index tap, so indexIsChanging is still false only
            // for a re-tap. That is the in-page re-tap contract: scroll
            // the current mode's feed to top, nothing else.
            if (!_tabController.indexIsChanging) {
              reTapScrollToTop(
                context,
                _scrollControllerFor(RankingMode.values[index]),
              );
            }
          },
          tabs: [
            for (final item in RankingMode.values)
              Tab(text: l10nLookupFor(language.locale, item.labelKey)),
          ],
        ),
      ),
      body: RootSwipeSwitcher(
        tabController: _tabController,
        // Warm the neighbor slots before a drag uncovers them — the strip
        // slide shows real feeds instead of blank placeholders.
        onPrepareAdjacent: (index) => setState(() {
          _loadedModes
            ..add((index - 1).clamp(0, RankingMode.values.length - 1))
            ..add((index + 1).clamp(0, RankingMode.values.length - 1));
        }),
        child: TabSlideStack(
          controller: _tabController,
          children: [
            for (var i = 0; i < RankingMode.values.length; i++)
              if (_loadedModes.contains(i))
                _RankingModeBody(
                  key: ValueKey(RankingMode.values[i]),
                  mode: RankingMode.values[i],
                  scrollController: _scrollControllerFor(RankingMode.values[i]),
                )
              else
                const SizedBox.shrink(),
          ],
        ),
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
      loading: () => const FeedLoading(),
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
          return const FeedLoading();
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
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref
                    .read(rankingFeedControllerProvider(mode).notifier)
                    .loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey('ranking-${mode.name}'),
                controller: controller,
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                restorationId: 'ranking-${mode.name}',
                slivers: [
                  IllustFeedGrid(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 10,
                    prefetchEntities: entities,
                    itemIds: [for (final e in entities) e.id],
                    itemCount: entities.length,
                    pagerLoadMore: () => ref
                        .read(rankingFeedControllerProvider(mode).notifier)
                        .loadMore(),
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
                  const SliverToBoxAdapter(child: FuncNavBarSpacer()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
