import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/feed_entrance.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/feed/feed_grid.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/novel_entry.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/network/api_date.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_ranking_feed_controller.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/theme/func_semantic_tokens.dart';
import 'ranking_date.dart';
import 'ranking_page.dart' show RankingRouteChanged;

/// Novel ranking page mirroring [RankingPage]: a horizontally scrollable
/// 9-mode tab bar with one keyed feed body per mode. The active mode is
/// route-durable (`?mode=`, `?date=`) — `initialMode` seeds the controller
/// and the route writes echo back through [onRouteChanged].
class NovelRankingPage extends StatefulWidget {
  const NovelRankingPage({
    super.key,
    this.initialMode = NovelRankingMode.day,
    this.date,
    this.onRouteChanged,
  });

  final NovelRankingMode initialMode;

  /// The ranking day from the route; null is the latest.
  final DateTime? date;
  final RankingRouteChanged<NovelRankingMode>? onRouteChanged;

  @override
  State<NovelRankingPage> createState() => _NovelRankingPageState();
}

class _NovelRankingPageState extends State<NovelRankingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _scrollControllers = <NovelRankingMode, ScrollController>{};
  final _entrancePlayed = <int>{};
  final _loadedModes = <int>{};

  /// One body instance per mode, reused across page builds: an identical
  /// widget short-circuits the element update, so the tab hop, route echo
  /// and drag warm-up that rebuild this page mid-swipe no longer rebuild
  /// every loaded feed (and its visible entries) inside the swipe frame.
  final _bodies = <NovelRankingMode, Widget>{};
  int _selectedIndex = 0;
  DateTime? _date;

  /// A context inside the Scaffold's notification scope, captured from the
  /// body's Builder: scroll announcements dispatched from here reach the
  /// app bar's ScrollNotificationObserver without passing the feeds' own
  /// NotificationListeners — a synthetic update must not trip load-more.
  late BuildContext _notificationContext;
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
    _date = widget.date;
  }

  @override
  void didUpdateWidget(NovelRankingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page key, so a route write lands here as
    // a widget update. Self-echoes (the write that just ran onRouteChanged)
    // carry the current mode and no-op; only an externally changed param
    // moves the strip — the controller is never reset.
    final index = NovelRankingMode.values.indexOf(widget.initialMode);
    if (widget.initialMode != oldWidget.initialMode &&
        index != _tabController.index) {
      // The controller listener would echo this move back through
      // onRouteChanged → context.replace — suppress it: the route already
      // carries this mode.
      _suppressRouteEcho = true;
      try {
        _tabController.index = index;
      } finally {
        _suppressRouteEcho = false;
      }
    }
    if (widget.date != _date) _resetForDate(widget.date);
  }

  /// A different day is a different list in every mode: drop the cached
  /// bodies and scroll positions, keep only the tab on screen loaded.
  void _resetForDate(DateTime? date) {
    final stale = _scrollControllers.values.toList();
    _scrollControllers.clear();
    _bodies.clear();
    _loadedModes
      ..clear()
      ..add(_selectedIndex);
    _date = date;
    // The outgoing lists still hold these until the next frame unmounts
    // them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in stale) {
        controller.dispose();
      }
    });
  }

  void _changeDate(DateTime? date) {
    if (date == _date) return;
    setState(() => _resetForDate(date));
    widget.onRouteChanged?.call(NovelRankingMode.values[_selectedIndex], date);
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
    // The app bar's scrolled-under state must follow the tab now on
    // screen, not the last list that scrolled.
    announceTabScroll(
      _notificationContext,
      _scrollControllerFor(NovelRankingMode.values[_selectedIndex]),
    );
    if (!_suppressRouteEcho) {
      widget.onRouteChanged?.call(
        NovelRankingMode.values[_selectedIndex],
        _date,
      );
    }
  }

  ScrollController _scrollControllerFor(NovelRankingMode mode) {
    return _scrollControllers.putIfAbsent(
      mode,
      () => ScrollController(
        onAttach: (_) {
          // A first-visited tab's list mounts after the tab-change
          // announce has already fired — re-announce so the app bar's
          // scrolled-under state still lands on the tab on screen.
          if (mode == NovelRankingMode.values[_selectedIndex]) {
            announceTabScroll(_notificationContext, _scrollControllers[mode]!);
          }
        },
      ),
    );
  }

  /// Every drag start lands here; only a first visit to a neighbour needs
  /// a rebuild.
  void _prepareAdjacent(int index) {
    final last = NovelRankingMode.values.length - 1;
    final neighbours = {(index - 1).clamp(0, last), (index + 1).clamp(0, last)};
    if (_loadedModes.containsAll(neighbours)) return;
    setState(() => _loadedModes.addAll(neighbours));
  }

  @override
  Widget build(BuildContext context) {
    final language = ReplicaLanguage.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return Scaffold(
      appBar: AppTopBar(
        titleSpacing: 0,
        actions: [RankingDateButton(date: _date, onChanged: _changeDate)],
        title: AppTabBar(
          controller: _tabController,
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
          labels: [
            for (final item in NovelRankingMode.values)
              l10nLookupFor(language.locale, item.labelKey),
          ],
        ),
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          final tabs = TabSwipeSwitcher(
            tabController: _tabController,
            // Warm the neighbor slots before a drag uncovers them.
            onPrepareAdjacent: _prepareAdjacent,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final (i, mode) in NovelRankingMode.values.indexed)
                  if (_loadedModes.contains(i))
                    _bodies.putIfAbsent(
                      mode,
                      () => _NovelRankingModeBody(
                        key: ValueKey((mode, _date)),
                        feedKey: (mode: mode, date: _date),
                        scrollController: _scrollControllerFor(mode),
                        entrancePlayed: _entrancePlayed,
                      ),
                    )
                  else
                    const SizedBox.shrink(),
              ],
            ),
          );
          // Always a Column, so the bar coming and going keeps the tab
          // strip's element.
          return Column(
            children: [
              if (_date case final date?)
                RankingDateBar(
                  date: date,
                  onBackToLatest: () => _changeDate(null),
                ),
              Expanded(child: tabs),
            ],
          );
        },
      ),
    );
  }
}

class _NovelRankingModeBody extends ConsumerWidget {
  const _NovelRankingModeBody({
    super.key,
    required this.feedKey,
    required this.scrollController,
    required this.entrancePlayed,
  });

  final NovelRankingFeedKey feedKey;
  final ScrollController scrollController;
  final Set<int> entrancePlayed;

  /// Scroll restoration per list: a past day is a different list from the
  /// latest one.
  String get _listId => switch (feedKey.date) {
    null => feedKey.mode.name,
    final date => '${feedKey.mode.name}-${formatApiDate(date)}',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(novelRankingFeedProvider(feedKey));
    final store = ref.watch(novelStoreProvider);
    return state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: l10nLookup(context.l10n, 'rankingLoadFailed'),
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () =>
            ref.read(novelRankingFeedProvider(feedKey).notifier).retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: l10nLookup(context.l10n, 'rankingLoadFailed'),
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(novelRankingFeedProvider(feedKey).notifier)
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
                ref.read(novelRankingFeedProvider(feedKey).notifier).refresh(),
          );
        }

        final entities = [
          for (final id in feed.ids)
            if (store[id] != null) store[id]!,
        ];
        return PullToRefresh(
          onRefresh: () =>
              ref.read(novelRankingFeedProvider(feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(novelRankingFeedProvider(feedKey).notifier).loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey('novel-ranking-$_listId'),
                controller: controller,
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                restorationId: 'novel-ranking-$_listId',
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(top: FuncSpacing.sm),
                    sliver: SliverList.builder(
                      itemCount: entities.length,
                      itemBuilder: (context, index) => StaggeredEntrance(
                        key: ValueKey(entities[index].id),
                        index: index,
                        id: entities[index].id,
                        played: entrancePlayed,
                        child: NovelEntry.ranking(
                          entity: entities[index],
                          rank: index + 1,
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(novelRankingFeedProvider(feedKey).notifier)
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
