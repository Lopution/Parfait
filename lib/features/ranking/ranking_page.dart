import 'package:material_ui/material_ui.dart';

import '../../app/navigation/routes.dart';
import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/replica_empty_state.dart';
import '../../core/entity/illust_store.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/network/api_date.dart';
import '../../core/network/api_error.dart';

import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/illust/ranking_feed_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import 'ranking_date.dart';

/// Records the page's mode and ranking day (null is the latest) in the
/// route.
typedef RankingRouteChanged<M> = void Function(M mode, DateTime? date);

/// Ranking page with beta56's horizontally scrollable 11-mode tab bar.
/// Only the selected mode is built, while controllers and scroll positions
/// remain cached by the page for tab switching. A past day ([date]) applies
/// to every mode.
class RankingPage extends StatefulWidget {
  const RankingPage({
    super.key,
    this.initialMode = RankingMode.day,
    this.date,
    this.onRouteChanged,
  });

  final RankingMode initialMode;

  /// The ranking day from the route; null is the latest.
  final DateTime? date;
  final RankingRouteChanged<RankingMode>? onRouteChanged;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _scrollControllers = <RankingMode, ScrollController>{};
  final _loadedModes = <int>{};

  /// One body instance per mode, reused across page builds: an identical
  /// widget short-circuits the element update, so the tab hop, route echo
  /// and drag warm-up that rebuild this page mid-swipe no longer rebuild
  /// every loaded feed (and its visible cards) inside the swipe frame.
  final _bodies = <RankingMode, Widget>{};
  int _selectedIndex = 0;
  DateTime? _date;

  /// A context inside the Scaffold's notification scope, captured from the
  /// body's Builder: scroll announcements dispatched from here reach the
  /// app bar's ScrollNotificationObserver without passing the feeds' own
  /// NotificationListeners — a synthetic update must not trip load-more.
  late BuildContext _notificationContext;
  ReTapChannel? _reTapChannel;

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
    _date = widget.date;
  }

  @override
  void didUpdateWidget(RankingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A route write lands here as a widget update; the echo of our own
    // write carries the day already shown and changes nothing.
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
    widget.onRouteChanged?.call(RankingMode.values[_selectedIndex], date);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final channel = HomeBranchStack.reTapOf(context);
    if (identical(channel, _reTapChannel)) return;
    _reTapChannel?.removeListener(_onBranchReTap);
    _reTapChannel = channel;
    _reTapChannel?.addListener(_onBranchReTap);
  }

  @override
  void dispose() {
    _reTapChannel?.removeListener(_onBranchReTap);
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
    // The app bar's scrolled-under state must follow the tab now on
    // screen, not the last list that scrolled.
    announceTabScroll(_notificationContext, _scrollControllerFor(mode));
    widget.onRouteChanged?.call(mode, _date);
  }

  ScrollController _scrollControllerFor(RankingMode mode) {
    return _scrollControllers.putIfAbsent(
      mode,
      () => ScrollController(
        onAttach: (_) {
          // A first-visited tab's list mounts after the tab-change
          // announce has already fired — re-announce so the app bar's
          // scrolled-under state still lands on the tab on screen.
          if (mode == RankingMode.values[_selectedIndex]) {
            announceTabScroll(_notificationContext, _scrollControllers[mode]!);
          }
        },
      ),
    );
  }

  /// Every drag start lands here; only a first visit to a neighbour needs
  /// a rebuild.
  void _prepareAdjacent(int index) {
    final last = RankingMode.values.length - 1;
    final neighbours = {(index - 1).clamp(0, last), (index + 1).clamp(0, last)};
    if (_loadedModes.containsAll(neighbours)) return;
    setState(() => _loadedModes.addAll(neighbours));
  }

  /// Branch-level re-tap (bottom bar same-destination tap): the channel
  /// fired after the branch stack popped, so the scroll lands post-frame
  /// on the now-visible root — a vetoed pop leaves a pushed route on top
  /// and `isCurrent` fails the scroll harmlessly.
  void _onBranchReTap() {
    if (_reTapChannel?.branch !=
        BranchRootScope.maybeOf(context)?.branchIndex) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      reTapScrollToTop(
        context,
        _scrollControllerFor(RankingMode.values[_selectedIndex]),
      );
    });
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
          RankingDateButton(date: _date, onChanged: _changeDate),
          IconButton(
            tooltip: context.l10n.novelRanking,
            onPressed: () => openNovelRanking(context),
            icon: const Icon(Icons.menu_book_outlined),
          ),
        ],
        title: AppTabBar(
          controller: _tabController,
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
          labels: [
            for (final item in RankingMode.values)
              l10nLookupFor(language.locale, item.labelKey),
          ],
        ),
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          final tabs = TabSwipeSwitcher(
            tabController: _tabController,
            // Warm the neighbor slots before a drag uncovers them — the
            // strip slide shows real feeds instead of blank placeholders.
            onPrepareAdjacent: _prepareAdjacent,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final (i, mode) in RankingMode.values.indexed)
                  if (_loadedModes.contains(i))
                    _bodies.putIfAbsent(
                      mode,
                      () => _RankingModeBody(
                        key: ValueKey((mode, _date)),
                        feedKey: (mode: mode, date: _date),
                        scrollController: _scrollControllerFor(mode),
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

class _RankingModeBody extends ConsumerWidget {
  const _RankingModeBody({
    super.key,
    required this.feedKey,
    required this.scrollController,
  });

  final RankingFeedKey feedKey;
  final ScrollController scrollController;

  RankingMode get mode => feedKey.mode;

  /// Scroll restoration and hero tags per list: a past day is a different
  /// list from the latest one.
  String get _listId => switch (feedKey.date) {
    null => mode.name,
    final date => '${mode.name}-${formatApiDate(date)}',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(rankingFeedControllerProvider(feedKey));
    final store = ref.watch(illustStoreProvider);
    return state.when(
      loading: () => IllustGridSkeleton(label: context.l10n.contentLoading),
      error: (error, _) => FeedError(
        title: l10nLookup(context.l10n, 'rankingLoadFailed'),
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref
            .read(rankingFeedControllerProvider(feedKey).notifier)
            .retryInitial(),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: l10nLookup(context.l10n, 'rankingLoadFailed'),
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(rankingFeedControllerProvider(feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return IllustGridSkeleton(label: context.l10n.contentLoading);
        }
        if (feed.isEmptyAndReady) {
          return ReplicaEmptyState(
            message: context.l10n.rankingEmpty,
            retryLabel: context.l10n.retry,
            onRetry: () => ref
                .read(rankingFeedControllerProvider(feedKey).notifier)
                .refresh(),
          );
        }

        final entities = store.getAll(feed.ids);
        return PullToRefresh(
          onRefresh: () => ref
              .read(rankingFeedControllerProvider(feedKey).notifier)
              .refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref
                    .read(rankingFeedControllerProvider(feedKey).notifier)
                    .loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey('ranking-$_listId'),
                controller: controller,
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                restorationId: 'ranking-$_listId',
                slivers: [
                  IllustFeedGrid(
                    prefetchEntities: entities,
                    itemIds: [for (final e in entities) e.id],
                    itemCount: entities.length,
                    pagerLoadMore: () => ref
                        .read(rankingFeedControllerProvider(feedKey).notifier)
                        .loadMore(),
                    itemBuilder: (context, index) => IllustCard(
                      entity: entities[index],
                      heroScope: 'ranking:$_listId',
                      rank: index + 1,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: FeedTail(
                      feed: feed,
                      onRetry: () => ref
                          .read(rankingFeedControllerProvider(feedKey).notifier)
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
