import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/icons/app_icons.dart';
import '../../../app/layout/card_columns.dart';
import '../../../app/layout/deferred_cache_scroll_view.dart';
import '../../../app/navigation/route_facade.dart';
import '../../../app/widgets/feed/desktop_inspectable_gallery.dart';
import '../../../app/pull_to_refresh.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_tab_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/author_summary.dart';
import '../../../app/widgets/feed/desktop_gallery_controls.dart';
import '../../../app/widgets/feed/feed_grid.dart';
import '../../../app/widgets/feed/feed_selection.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/widgets/feed/load_more_listener.dart';
import '../../../app/widgets/func_bottom_nav.dart';
import '../../../app/widgets/home_branch_stack.dart';
import '../../../app/widgets/novel_entry.dart';
import '../../../app/widgets/page_header.dart';
import '../../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../../app/widgets/skeleton/list_skeletons.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';
import '../../../app/widgets/tab_swipe_switcher.dart';
import '../../../app/widgets/user_preview_row.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/entity/stored_entities.dart';
import '../../../core/illust/recommended_feed_controller.dart';
import '../../../core/illust/recommended_repository.dart';
import '../../../core/navigation/home_destination.dart';
import '../../../core/network/api_error.dart';
import '../../../core/novel/novel_store.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../core/user/user_store.dart';
import '../../../l10n/context.dart';
import '../../../l10n/lookup.dart';

String _recommendedText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

String _recommendedLabelKey(RecommendedContentType type) => switch (type) {
  RecommendedContentType.illust => 'recommendedIllust',
  RecommendedContentType.manga => 'recommendedManga',
  RecommendedContentType.novel => 'recommendedNovel',
  RecommendedContentType.user => 'recommendedUser',
};

/// Home recommended tab with the beta56 content selector:
/// 插画 / 漫画 / 小说 / 用户. The active type is route-durable
/// (`/recommended?type=`): [initialType] seeds the controller and tab
/// changes echo back through [onTypeChanged]. Each type keeps its own
/// cursor/scroll state via the TabSlideStack, so switching back does not
/// refetch.
/// Grid padding shared by the feed sliver and its first-load skeleton.
const _gridPadding = IllustFeedGrid.defaultPadding;

class RecommendedHomePage extends ConsumerStatefulWidget {
  const RecommendedHomePage({
    super.key,
    this.initialType = RecommendedContentType.illust,
    this.onTypeChanged,
  });

  final RecommendedContentType initialType;
  final ValueChanged<RecommendedContentType>? onTypeChanged;

  @override
  ConsumerState<RecommendedHomePage> createState() =>
      _RecommendedHomePageState();
}

class _RecommendedHomePageState extends ConsumerState<RecommendedHomePage>
    with SingleTickerProviderStateMixin {
  static const _types = RecommendedContentType.values;

  late final TabController _tabController;
  late RecommendedContentType _type;
  final _loaded = <RecommendedContentType>{};
  final _scrollControllers = <RecommendedContentType, ScrollController>{};

  /// One body instance per type, reused across page builds: an identical
  /// widget short-circuits the element update, so the tab hop, route echo
  /// and drag warm-up that rebuild this page mid-swipe no longer rebuild
  /// every loaded feed (and its visible cards) inside the swipe frame.
  final _bodies = <RecommendedContentType, Widget>{};
  bool _suppressRouteEcho = false;
  ReTapChannel? _reTapChannel;
  late BuildContext _notificationContext;

  /// Unused placeholder removed.

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
          if (type == _type) {
            announceTabScroll(_notificationContext, _scrollControllers[type]!);
          }
        },
      ),
    );
  }

  bool _prepareTab(int index) {
    final type = _types[index];
    if (_loaded.contains(type)) return false;
    setState(() => _loaded.add(type));
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final showGalleryControls =
        _type == RecommendedContentType.illust ||
        _type == RecommendedContentType.manga;
    final labels = [
      for (final value in _types)
        _recommendedText(context, _recommendedLabelKey(value)),
    ];
    final tabBody = Builder(
      builder: (context) {
        _notificationContext = context;
        return TabSwipeSwitcher(
          tabController: _tabController,
          prepareTab: _prepareTab,
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
                    ),
                  )
                else
                  const SizedBox.shrink(),
            ],
          ),
        );
      },
    );

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppTopBar(
        titleSpacing: 0,
        actions: [
          DesktopGalleryControls(visible: showGalleryControls),
          const _OffBarSearchAction(),
          const HeaderRefresh(),
          const HeaderSearch(),
        ],
        title: AppTabBar(
          controller: _tabController,
          onTap: (index) {
            if (!_tabController.indexIsChanging) {
              reTapScrollToTop(context, _scrollControllerFor(_types[index]));
            }
          },
          labels: labels,
        ),
      ),
      body: DesktopInspectableGallery(
        active: showGalleryControls,
        scopeKey: _types[_tabController.index],
        child: tabBody,
      ),
    );
  }
}

/// One keyed recommended feed body. Watches [recommendedFeedProvider] and
/// renders the right card shape for the type.
class _RecommendedFeedView extends ConsumerWidget {
  const _RecommendedFeedView({
    super.key,
    required this.type,
    required this.scrollController,
  });

  final RecommendedContentType type;
  final ScrollController scrollController;

  Widget _initialSkeleton(BuildContext context) => switch (type) {
    RecommendedContentType.novel => NovelListSkeleton(
      label: context.l10n.contentLoading,
    ),
    RecommendedContentType.user => UserListSkeleton(
      label: context.l10n.contentLoading,
    ),
    RecommendedContentType.illust ||
    RecommendedContentType.manga => IllustGridSkeleton(
      label: context.l10n.contentLoading,
      padding: _gridPadding,
    ),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (type: type);
    listenFeedRefreshError(
      context,
      ref,
      recommendedFeedProvider(key),
      controller: () => ref.read(recommendedFeedProvider(key).notifier),
      action: context.l10n.recommendedRefreshFailed,
    );
    final feedAsync = ref.watch(recommendedFeedProvider(key));

    return feedAsync.when(
      loading: () => _initialSkeleton(context),
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
          return _initialSkeleton(context);
        }
        final controller = ref.read(recommendedFeedProvider(key).notifier);
        // User recommendations are not filtered: an empty page there is
        // not the filters' doing.
        if (feed.isAllHidden && controller.localFilterEnabled) {
          return FeedAllHidden(
            feed: feed,
            onLoadMore: controller.retryLoadMore,
          );
        }
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            title: context.l10n.recommendedEmpty,
            retryLabel: context.l10n.refresh,
            onRefresh: () =>
                ref.read(recommendedFeedProvider(key).notifier).refresh(),
          );
        }
        return _RecommendedFeedBody(
          type: type,
          feed: feed,
          scrollController: scrollController,
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
    required this.onRefresh,
    required this.onLoadMore,
    required this.onRetryLoadMore,
  });

  final RecommendedContentType type;
  final PagedFeedState feed;
  final ScrollController scrollController;
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

    final scrollHost = PullToRefresh(
      scrollController: scrollController,
      onRefresh: onRefresh,
      child: LoadMoreListener(
        itemCount: feed.ids.length,
        onLoadMore: onLoadMore,
        child: SmoothWheelScroll(
          // Explicit per-type controller so re-tap can reach the active
          // feed; without it desktop wheel scrolling would own a private
          // controller the channel cannot address.
          controller: scrollController,
          basePhysics: const AlwaysScrollableScrollPhysics(),
          builder: (context, controller, physics) => DeferredCacheScrollView(
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
    return switch (type) {
      RecommendedContentType.illust ||
      RecommendedContentType.manga => SelectableFeedHost(child: scrollHost),
      RecommendedContentType.novel || RecommendedContentType.user => scrollHost,
    };
  }

  List<Widget> _illustSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final store = ref.watch(illustStoreProvider);
    final entities = store.getAll(feed.ids);
    final heroScope = 'recommended:${type.name}';
    return [
      IllustFeedGrid(
        padding: _gridPadding,
        itemIds: [for (final e in entities) e.id],
        itemCount: entities.length,
        pagerLoadMore: onLoadMore,
        warmTexts: (context, index) =>
            IllustCard.warmTexts(context, entities[index]),
        items: entities,
        itemDeps: heroScope,
        itemBuilder: (context, index) =>
            IllustCard(entity: entities[index], heroScope: heroScope),
      ),
      ...tail,
    ];
  }

  List<Widget> _novelSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final novels = ref
        .watch(
          novelStoreProvider.select((store) => StoredEntities(store, feed.ids)),
        )
        .items;
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: FuncSpacing.sm),
        sliver: SliverCardList(
          itemCount: novels.length,
          firstId: novels.firstOrNull?.id,
          warmTexts: (context, index) =>
              NovelEntry.warmTexts(context, novels[index]),
          items: novels,
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(novels[index].id),
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
    final users = ref
        .watch(
          userStoreProvider.select((store) => StoredEntities(store, feed.ids)),
        )
        .items;
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: FuncSpacing.sm),
        sliver: SliverCardList(
          itemCount: users.length,
          firstId: users.firstOrNull?.id,
          warmTexts: (context, index) => AuthorSummary.warmTexts(
            context,
            name: users[index].name,
            account: UserPreviewRow.handleOf(users[index]),
          ),
          items: users,
          itemBuilder: (context, index) => KeyedSubtree(
            key: ValueKey(users[index].id),
            child: UserPreviewRow(entity: users[index]),
          ),
        ),
      ),
      ...tail,
    ];
  }
}

/// Search's way in when the user took it off the bar.
class _OffBarSearchAction extends ConsumerWidget {
  const _OffBarSearchAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The wide header's own search field is the way in there (R7).
    if (PageHeader.isWide(context)) return const SizedBox.shrink();
    final offBar = ref.watch(
      homeArrangementProvider.select(
        (arrangement) => !arrangement.shown.contains(HomeDestination.search),
      ),
    );
    if (!offBar) return const SizedBox.shrink();
    return IconButton(
      tooltip: context.l10n.searchTitle,
      icon: const Icon(AppIcons.search),
      onPressed: () => openHomeDestination(context, HomeDestination.search),
    );
  }
}
