import 'package:material_ui/material_ui.dart';

import '../../../app/motion/press_scale.dart';
import '../../../app/motion/feed_entrance.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/pull_to_refresh.dart';
import '../../../app/navigation/routes.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/novel/novel_store.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../core/user/user_entity.dart';
import '../../../core/user/user_store.dart';
import '../../../core/illust/recommended_feed_controller.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../../app/widgets/app_tab_bar.dart';
import '../../../app/widgets/home_branch_stack.dart';
import '../../../app/widgets/func_bottom_nav.dart';
import '../../../app/widgets/tab_swipe_switcher.dart';
import '../../../app/widgets/author_summary.dart';
import '../../../app/widgets/novel_entry.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../core/illust/recommended_repository.dart';
import '../../../l10n/context.dart';
import '../../../l10n/lookup.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';

String _recommendedText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

/// Home recommended tab with the beta56 content selector:
/// 插画 / 漫画 / 小说 / 用户. The active type is route-durable
/// (`/recommended?type=`): [initialType] seeds the controller and tab
/// changes echo back through [onTypeChanged]. Each type keeps its own
/// cursor/scroll state via the TabSlideStack, so switching back does not
/// refetch.
/// Grid padding shared by the feed sliver and its first-load skeleton.
const _gridPadding = EdgeInsets.fromLTRB(FuncSpacing.sm, 0, FuncSpacing.sm, 0);

class RecommendedHomePage extends StatefulWidget {
  const RecommendedHomePage({
    super.key,
    this.initialType = RecommendedContentType.illust,
    this.onTypeChanged,
  });

  final RecommendedContentType initialType;
  final ValueChanged<RecommendedContentType>? onTypeChanged;

  @override
  State<RecommendedHomePage> createState() => _RecommendedHomePageState();
}

class _RecommendedHomePageState extends State<RecommendedHomePage>
    with SingleTickerProviderStateMixin {
  static const _types = RecommendedContentType.values;

  late final TabController _tabController;
  late RecommendedContentType _type;
  final _loaded = <RecommendedContentType>{};
  final _scrollControllers = <RecommendedContentType, ScrollController>{};
  final _entrancePlayed = <RecommendedContentType, Set<int>>{};

  /// One body instance per type, reused across page builds: an identical
  /// widget short-circuits the element update, so the tab hop, route echo
  /// and drag warm-up that rebuild this page mid-swipe no longer rebuild
  /// every loaded feed (and its visible cards) inside the swipe frame.
  final _bodies = <RecommendedContentType, Widget>{};
  bool _suppressRouteEcho = false;
  ReTapChannel? _reTapChannel;

  /// A context inside the Scaffold's notification scope, captured from the
  /// body's Builder: scroll announcements dispatched from here reach the
  /// app bar's ScrollNotificationObserver without passing the feeds' own
  /// NotificationListeners — a synthetic update must not trip load-more.
  late BuildContext _notificationContext;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _loaded.add(_type);
    _tabController = TabController(
      length: _types.length,
      vsync: this,
      initialIndex: _types.indexOf(_type),
    )..addListener(_onTabChanged);
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
  void didUpdateWidget(RecommendedHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page key, so a route write lands here as
    // a widget update. Self-echoes carry the current type and no-op; only
    // an externally changed param moves the strip — the controller is
    // never reset.
    final index = _types.indexOf(widget.initialType);
    if (widget.initialType != oldWidget.initialType &&
        index != _tabController.index) {
      // The controller listener would echo this move back through
      // onTypeChanged → context.replace — suppress it: the route already
      // carries this type.
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
    _reTapChannel?.removeListener(_onBranchReTap);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _types.indexOf(_type)) return;
    setState(() {
      _type = _types[_tabController.index];
      _loaded.add(_type);
    });
    // The app bar's scrolled-under state must follow the tab now on
    // screen, not the last list that scrolled.
    announceTabScroll(_notificationContext, _scrollControllerFor(_type));
    if (!_suppressRouteEcho) {
      widget.onTypeChanged?.call(_type);
    }
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
      reTapScrollToTop(context, _scrollControllerFor(_type));
    });
  }

  ScrollController _scrollControllerFor(RecommendedContentType type) {
    return _scrollControllers.putIfAbsent(
      type,
      () => ScrollController(
        onAttach: (_) {
          // A first-visited tab's list mounts after the tab-change
          // announce has already fired — re-announce so the app bar's
          // scrolled-under state still lands on the tab on screen.
          if (type == _type) {
            announceTabScroll(_notificationContext, _scrollControllers[type]!);
          }
        },
      ),
    );
  }

  /// Every drag start lands here; only a first visit to a neighbour needs
  /// a rebuild.
  void _prepareAdjacent(int index) {
    final neighbours = {
      _types[(index - 1).clamp(0, _types.length - 1)],
      _types[(index + 1).clamp(0, _types.length - 1)],
    };
    if (_loaded.containsAll(neighbours)) return;
    setState(() => _loaded.addAll(neighbours));
  }

  @override
  Widget build(BuildContext context) {
    // Same chrome as Ranking/New/Search: AppBar with an embedded TabBar.
    // Before this the selector was a bare TabBar pinned below the status
    // bar, which visually diverged from every other tab (no AppBar height,
    // no surface elevation) — the three tabs looked like three apps.
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 0,
        title: _RecommendedTypeSelector(
          controller: _tabController,
          onTap: (index) {
            // _changeIndex early-returns on a same-index tap, so
            // indexIsChanging is still false only for a re-tap: scroll the
            // current type's feed to top, nothing else.
            if (!_tabController.indexIsChanging) {
              reTapScrollToTop(context, _scrollControllerFor(_types[index]));
            }
          },
        ),
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          return TabSwipeSwitcher(
            tabController: _tabController,
            // A neighbor the finger is about to uncover has to exist before
            // the slide starts — same offscreen-page warmup ViewPager does.
            onPrepareAdjacent: _prepareAdjacent,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final type in _types)
                  if (_loaded.contains(type))
                    _bodies.putIfAbsent(
                      type,
                      () => _RecommendedFeedView(
                        key: ValueKey(type),
                        type: type,
                        scrollController: _scrollControllerFor(type),
                        entrancePlayed: _entrancePlayed.putIfAbsent(
                          type,
                          () => {},
                        ),
                      ),
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

class _RecommendedTypeSelector extends StatelessWidget {
  const _RecommendedTypeSelector({
    required this.controller,
    required this.onTap,
  });

  final TabController controller;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    // Same chrome as Ranking/New/Search: a bare AppTabBar inside the
    // AppBar title (no extra Material/SizedBox — the AppBar constrains
    // height and provides the surface).
    return AppTabBar(
      controller: controller,
      onTap: onTap,
      labels: [
        for (final value in RecommendedContentType.values)
          _recommendedText(context, _labelKey(value)),
      ],
    );
  }

  static String _labelKey(RecommendedContentType type) => switch (type) {
    RecommendedContentType.illust => 'recommendedIllust',
    RecommendedContentType.manga => 'recommendedManga',
    RecommendedContentType.novel => 'recommendedNovel',
    RecommendedContentType.user => 'recommendedUser',
  };
}

/// One keyed recommended feed body. Watches [recommendedFeedProvider] and
/// renders the right card shape for the type.
class _RecommendedFeedView extends ConsumerWidget {
  const _RecommendedFeedView({
    super.key,
    required this.type,
    required this.scrollController,
    required this.entrancePlayed,
  });

  final RecommendedContentType type;
  final ScrollController scrollController;
  final Set<int> entrancePlayed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (type: type);
    // Refresh failure keeps the loaded feed and surfaces as a transient
    // banner anchored to this page's ScaffoldMessenger — the inline tail
    // row it replaced rendered "${feed.loadMoreError}", which the phase
    // copy never populated ("null").
    ref.listen(recommendedFeedProvider(key), (previous, next) {
      final feed = next.asData?.value;
      final wasError = previous?.asData?.value.refreshPhase == FeedPhase.error;
      if (feed == null || feed.refreshPhase != FeedPhase.error || wasError) {
        return;
      }
      final error = ref
          .read(recommendedFeedProvider(key).notifier)
          .consumeRefreshError();
      if (error == null) return;
      showErrorSnackBar(
        context,
        action: context.l10n.recommendedRefreshFailed,
        error: error,
        snackBarAction: SnackBarAction(
          label: context.l10n.retry,
          onPressed: () =>
              ref.read(recommendedFeedProvider(key).notifier).refresh(),
        ),
      );
    });
    final feedAsync = ref.watch(recommendedFeedProvider(key));

    return feedAsync.when(
      loading: () => IllustGridSkeleton(
        label: context.l10n.contentLoading,
        padding: _gridPadding,
      ),
      error: (error, _) => FeedError(
        title: context.l10n.recommendedLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref.invalidate(recommendedFeedProvider(key)),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.recommendedLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () =>
                ref.read(recommendedFeedProvider(key).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return IllustGridSkeleton(
            label: context.l10n.contentLoading,
            padding: _gridPadding,
          );
        }
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            title: context.l10n.recommendedEmpty,
            retryLabel: context.l10n.retry,
            onRefresh: () =>
                ref.read(recommendedFeedProvider(key).notifier).refresh(),
          );
        }
        return _RecommendedFeedBody(
          type: type,
          feed: feed,
          scrollController: scrollController,
          entrancePlayed: entrancePlayed,
          onRefresh: () =>
              ref.read(recommendedFeedProvider(key).notifier).refresh(),
          onLoadMore: () =>
              ref.read(recommendedFeedProvider(key).notifier).loadMore(),
          onRetryLoadMore: () =>
              ref.read(recommendedFeedProvider(key).notifier).retryLoadMore(),
        );
      },
    );
  }
}

class _RecommendedFeedBody extends ConsumerWidget {
  const _RecommendedFeedBody({
    required this.type,
    required this.feed,
    required this.scrollController,
    required this.entrancePlayed,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onRetryLoadMore,
  });

  final RecommendedContentType type;
  final PagedFeedState feed;
  final ScrollController scrollController;
  final Set<int> entrancePlayed;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tail = <Widget>[
      SliverToBoxAdapter(
        child: FeedTail(
          feed: feed,
          onRetry: onRetryLoadMore,
          endMessage: context.l10n.recommendedEnd,
          retryLabel: context.l10n.retry,
        ),
      ),
      const SliverToBoxAdapter(child: FuncNavBarSpacer()),
    ];

    final slivers = switch (type) {
      RecommendedContentType.illust ||
      RecommendedContentType.manga => _illustSlivers(context, ref, tail),
      RecommendedContentType.novel => _novelSlivers(context, ref, tail),
      RecommendedContentType.user => _userSlivers(context, ref, tail),
    };

    return PullToRefresh(
      onRefresh: onRefresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter <
                  notification.metrics.viewportDimension * 1.2) {
            onLoadMore();
          }
          return false;
        },
        child: SmoothWheelScroll(
          // Explicit per-type controller so re-tap can reach the active
          // feed; without it desktop wheel scrolling would own a private
          // controller the channel cannot address.
          controller: scrollController,
          basePhysics: const AlwaysScrollableScrollPhysics(),
          builder: (context, controller, physics) => CustomScrollView(
            key: PageStorageKey('recommended-${type.name}'),
            physics: physics,
            scrollCacheExtent: kFeedCacheExtent,
            restorationId: 'recommended-${type.name}',
            controller: controller,
            slivers: slivers,
          ),
        ),
      ),
    );
  }

  List<Widget> _illustSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final store = ref.watch(illustStoreProvider);
    final entities = store.getAll(feed.ids);
    return [
      IllustFeedGrid(
        padding: _gridPadding,
        prefetchEntities: entities,
        itemIds: [for (final e in entities) e.id],
        itemCount: entities.length,
        pagerLoadMore: onLoadMore,
        itemBuilder: (context, index) => IllustCard(
          entity: entities[index],
          heroScope: 'recommended:${type.name}',
        ),
      ),
      ...tail,
    ];
  }

  List<Widget> _novelSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final storedNovels = ref.watch(novelStoreProvider);
    final novels = [
      for (final id in feed.ids)
        if (storedNovels[id] != null) storedNovels[id]!,
    ];
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: FuncSpacing.sm),
        sliver: SliverList.builder(
          itemCount: novels.length,
          itemBuilder: (context, index) => StaggeredEntrance(
            key: ValueKey(novels[index].id),
            index: index,
            id: novels[index].id,
            played: entrancePlayed,
            child: NovelEntry.compact(entity: novels[index]),
          ),
        ),
      ),
      ...tail,
    ];
  }

  List<Widget> _userSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final storedUsers = ref.watch(userStoreProvider);
    final users = [
      for (final id in feed.ids)
        if (storedUsers[id] != null) storedUsers[id]!,
    ];
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: FuncSpacing.sm),
        sliver: SliverList.builder(
          itemCount: users.length,
          itemBuilder: (context, index) => StaggeredEntrance(
            key: ValueKey(users[index].id),
            index: index,
            id: users[index].id,
            played: entrancePlayed,
            child: _UserRow(entity: users[index]),
          ),
        ),
      ),
      ...tail,
    ];
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.entity});

  final UserEntity entity;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.md,
          vertical: FuncSpacing.sm,
        ),
        child: InkWell(
          onTap: () => openUser(context, entity.id),
          borderRadius: FuncShape.control,
          child: Padding(
            padding: const EdgeInsets.all(FuncSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: AuthorSummary(
                    name: entity.name,
                    account: entity.account,
                    imageUrl: entity.profileImageUrl,
                    avatarRadius: 24,
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
