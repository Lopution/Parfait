import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/feed_entrance.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/branch_slide_stack.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_row.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../app/widgets/root_swipe_switcher.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_ranking_feed_controller.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

/// Novel ranking page mirroring [RankingPage]: a horizontally scrollable
/// 9-mode tab bar with one keyed feed body per mode. The active mode is
/// route-durable (`?mode=`) — `initialMode` seeds the controller and the
/// route writes echo back through [onModeChanged].
class NovelRankingPage extends StatefulWidget {
  const NovelRankingPage({
    super.key,
    this.initialMode = NovelRankingMode.day,
    this.onModeChanged,
  });

  final NovelRankingMode initialMode;
  final ValueChanged<NovelRankingMode>? onModeChanged;

  @override
  State<NovelRankingPage> createState() => _NovelRankingPageState();
}

class _NovelRankingPageState extends State<NovelRankingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _scrollControllers = <NovelRankingMode, ScrollController>{};
  final _entrancePlayed = <int>{};
  final _loadedModes = <int>{};
  int _selectedIndex = 0;
  bool _suppressRouteEcho = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: NovelRankingMode.values.length,
      vsync: this,
      initialIndex: NovelRankingMode.values.indexOf(widget.initialMode),
    )..addListener(_handleTabChanged);
    _selectedIndex = _tabController.index;
    _loadedModes.add(_selectedIndex);
  }

  @override
  void didUpdateWidget(NovelRankingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page key, so a route write lands here as
    // a widget update. Self-echoes (the write that just ran onModeChanged)
    // carry the current mode and no-op; only an externally changed param
    // moves the strip — the controller is never reset.
    final index = NovelRankingMode.values.indexOf(widget.initialMode);
    if (widget.initialMode != oldWidget.initialMode &&
        index != _tabController.index) {
      // The controller listener would echo this move back through
      // onModeChanged → context.replace — suppress it: the route already
      // carries this mode.
      _suppressRouteEcho = true;
      try {
        _tabController.index = index;
      } finally {
        _suppressRouteEcho = false;
      }
    }
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
    setState(() {
      _selectedIndex = _tabController.index;
      _loadedModes.add(_selectedIndex);
    });
    if (!_suppressRouteEcho) {
      widget.onModeChanged?.call(NovelRankingMode.values[_selectedIndex]);
    }
  }

  ScrollController _scrollControllerFor(NovelRankingMode mode) {
    return _scrollControllers.putIfAbsent(mode, ScrollController.new);
  }

  @override
  Widget build(BuildContext context) {
    final language = ReplicaLanguage.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
    );
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
          onTap: (index) {
            // Same-index taps never reach _changeIndex (it early-returns),
            // so indexIsChanging is false exactly for a re-tap: scroll the
            // current mode's feed to top, nothing else.
            if (!_tabController.indexIsChanging) {
              reTapScrollToTop(
                context,
                _scrollControllerFor(NovelRankingMode.values[index]),
              );
            }
          },
          tabs: [
            for (final item in NovelRankingMode.values)
              Tab(text: l10nLookupFor(language.locale, item.labelKey)),
          ],
        ),
      ),
      body: RootSwipeSwitcher(
        tabController: _tabController,
        // Warm the neighbor slots before a drag uncovers them.
        onPrepareAdjacent: (index) => setState(() {
          _loadedModes
            ..add((index - 1).clamp(0, NovelRankingMode.values.length - 1))
            ..add((index + 1).clamp(0, NovelRankingMode.values.length - 1));
        }),
        child: TabSlideStack(
          controller: _tabController,
          children: [
            for (var i = 0; i < NovelRankingMode.values.length; i++)
              if (_loadedModes.contains(i))
                _NovelRankingModeBody(
                  key: ValueKey(NovelRankingMode.values[i]),
                  mode: NovelRankingMode.values[i],
                  scrollController: _scrollControllerFor(
                    NovelRankingMode.values[i],
                  ),
                  entrancePlayed: _entrancePlayed,
                )
              else
                const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

class _NovelRankingModeBody extends ConsumerWidget {
  const _NovelRankingModeBody({
    super.key,
    required this.mode,
    required this.scrollController,
    required this.entrancePlayed,
  });

  final NovelRankingMode mode;
  final ScrollController scrollController;
  final Set<int> entrancePlayed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(novelRankingFeedProvider(mode));
    final store = ref.watch(novelStoreProvider);
    return state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: l10nLookup(context.l10n, 'rankingLoadFailed'),
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () =>
            ref.read(novelRankingFeedProvider(mode).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: l10nLookup(context.l10n, 'rankingLoadFailed'),
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(novelRankingFeedProvider(mode).notifier)
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
            onRetry: () =>
                ref.read(novelRankingFeedProvider(mode).notifier).refresh(),
          );
        }

        final entities = [
          for (final id in feed.ids)
            if (store[id] != null) store[id]!,
        ];
        return PullToRefresh(
          onRefresh: () =>
              ref.read(novelRankingFeedProvider(mode).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(novelRankingFeedProvider(mode).notifier).loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey('novel-ranking-${mode.name}'),
                controller: controller,
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                restorationId: 'novel-ranking-${mode.name}',
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 8),
                    sliver: SliverList.builder(
                      itemCount: entities.length,
                      itemBuilder: (context, index) => StaggeredEntrance(
                        key: ValueKey(entities[index].id),
                        index: index,
                        id: entities[index].id,
                        played: entrancePlayed,
                        child: NovelRow(entity: entities[index]),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(novelRankingFeedProvider(mode).notifier)
                          .retryLoadMore(),
                      errorTitle: context.l10n.rankingLoadMoreFailed,
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
