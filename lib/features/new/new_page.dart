import 'package:material_ui/material_ui.dart';

import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/novel_entry.dart';
import '../../core/entity/illust_store.dart';
import '../../core/new/new_feed_controller.dart';
import '../../core/new/new_feed_models.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// Beta56 New page for one content [type]: scope tabs over that type's
/// feeds, the same shape as the ranking pages. The illust page is the
/// branch root and opens the novel page from its app bar, as the ranking
/// page opens the novel ranking. The scope is route-durable
/// (`?scope=`): [initialScope] seeds the tabs and tab changes echo back
/// through [onScopeChanged]. Each scope keeps its own feed state, scroll
/// offset and cursor — switching back does not refetch.
class NewPage extends StatefulWidget {
  const NewPage({
    super.key,
    this.type = NewFeedType.illust,
    this.initialScope = NewFeedScope.following,
    this.onScopeChanged,
  });

  final NewFeedType type;
  final NewFeedScope initialScope;
  final ValueChanged<NewFeedScope>? onScopeChanged;

  @override
  State<NewPage> createState() => _NewPageState();
}

class _NewPageState extends State<NewPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _loadedKeys = <NewFeedKey>{};
  final _scrollControllers = <NewFeedKey, ScrollController>{};

  /// One body instance per feed key, reused across page builds: an
  /// identical widget short-circuits the element update, so the tab hop,
  /// route echo and drag warm-up that rebuild this page mid-swipe no
  /// longer rebuild every loaded feed (and its visible cards) inside the
  /// swipe frame.
  final _bodies = <NewFeedKey, Widget>{};
  late int _selectedIndex;
  bool _suppressRouteEcho = false;
  ReTapChannel? _reTapChannel;

  /// A context inside the Scaffold's notification scope, captured from the
  /// body's Builder: scroll announcements dispatched from here reach the
  /// app bar's ScrollNotificationObserver without passing the feeds' own
  /// NotificationListeners — a synthetic update must not trip load-more.
  late BuildContext _notificationContext;

  static const _scopes = NewFeedScope.values;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _scopes.indexOf(widget.initialScope);
    _loadedKeys.add(_activeKey);
    _tabController = TabController(
      length: _scopes.length,
      vsync: this,
      initialIndex: _selectedIndex,
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
  void didUpdateWidget(NewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page key, so a route write lands here as a
    // widget update. Self-echoes carry the current scope and no-op; only
    // an externally changed param moves the strip — the controller is
    // never reset.
    if (widget.initialScope == _scopes[_selectedIndex]) return;
    setState(() => _loadedKeys.add(_keyFor(widget.initialScope)));
    final index = _scopes.indexOf(widget.initialScope);
    if (index != _tabController.index) {
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

  NewFeedKey _keyFor(NewFeedScope scope) =>
      NewFeedKey(scope: scope, type: widget.type);

  NewFeedKey get _activeKey => _keyFor(_scopes[_selectedIndex]);

  ScrollController _scrollControllerFor(NewFeedKey key) =>
      _scrollControllers.putIfAbsent(
        key,
        () => ScrollController(
          onAttach: (_) {
            // A first-visited tab's list mounts after the tab-change
            // announce has already fired — re-announce so the app bar's
            // scrolled-under state still lands on the tab on screen.
            if (key == _activeKey) {
              announceTabScroll(_notificationContext, _scrollControllers[key]!);
            }
          },
        ),
      );

  /// Every drag start lands here; only a first visit to a neighbour needs
  /// a rebuild.
  void _prepareAdjacent(int index) {
    final neighbours = {
      for (final i in [index - 1, index + 1])
        if (i >= 0 && i < _scopes.length) _keyFor(_scopes[i]),
    };
    if (_loadedKeys.containsAll(neighbours)) return;
    setState(() => _loadedKeys.addAll(neighbours));
  }

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex) return;
    setState(() {
      _selectedIndex = _tabController.index;
      _loadedKeys.add(_activeKey);
    });
    // The app bar's scrolled-under state must follow the tab now on
    // screen, not the last list that scrolled.
    announceTabScroll(_notificationContext, _scrollControllerFor(_activeKey));
    if (!_suppressRouteEcho) {
      widget.onScopeChanged?.call(_scopes[_selectedIndex]);
    }
  }

  void _onTabTap(int index) {
    // A same-index scope tap scrolls the visible feed to top — it never
    // refreshes or changes selection.
    if (index == _selectedIndex && !_tabController.indexIsChanging) {
      reTapScrollToTop(context, _scrollControllerFor(_activeKey));
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
      reTapScrollToTop(context, _scrollControllerFor(_activeKey));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppTopBar(
        titleSpacing: 0,
        title: AppTabBar(
          controller: _tabController,
          onTap: _onTabTap,
          labels: [
            for (final scope in _scopes)
              _newText(context, _scopeLabelKey(scope)),
          ],
        ),
        // Same entry as the ranking page's novel ranking. Other feature
        // entries (watchlist, local novels) live in the Me tab's content
        // group.
        actions: [
          if (widget.type == NewFeedType.illust)
            IconButton(
              tooltip: context.l10n.newNovels,
              onPressed: () => openNewNovels(context),
              icon: const Icon(Icons.menu_book_outlined),
            ),
        ],
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
                for (final key in _scopes.map(_keyFor))
                  // A scope slot builds its feed on first visit (or swipe
                  // warm-up) and keeps it from then on.
                  if (_loadedKeys.contains(key))
                    _bodies.putIfAbsent(
                      key,
                      () => _NewFeedBody(
                        key: ValueKey(key),
                        feedKey: key,
                        scrollController: _scrollControllerFor(key),
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

  String _scopeLabelKey(NewFeedScope scope) => switch (scope) {
    NewFeedScope.following => 'newFollowing',
    NewFeedScope.everyone => 'newEveryone',
    NewFeedScope.myPixiv => 'newMyPixiv',
  };
}

/// One keyed feed body. The state is kept alive by [NewPage]'s scope stack
/// so scroll/cursor/error state is not shared with another scope.
/// [scrollController] is owned by the page (one per [NewFeedKey]) so re-tap
/// gestures can address the visible feed.
class _NewFeedBody extends ConsumerWidget {
  const _NewFeedBody({
    super.key,
    required this.feedKey,
    required this.scrollController,
  });

  final NewFeedKey feedKey;
  final ScrollController scrollController;

  Widget _loading(BuildContext context) => feedKey.type == NewFeedType.illust
      ? IllustGridSkeleton(label: context.l10n.newLoading)
      : FeedLoading(label: context.l10n.newLoading);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(newFeedProvider(feedKey));
    return feedAsync.when(
      loading: () => _loading(context),
      error: (error, _) => FeedError(
        title: context.l10n.newLoadFailed,
        error: error,
        retryLabel: context.l10n.newRetry,
        onRetry: () => ref.invalidate(newFeedProvider(feedKey)),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.newLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.newRetry,
            onRetry: () =>
                ref.read(newFeedProvider(feedKey).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner) return _loading(context);
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            icon: Icons.inbox_outlined,
            title: context.l10n.newEmpty,
            retryLabel: context.l10n.refresh,
            onRefresh: () =>
                ref.read(newFeedProvider(feedKey).notifier).refresh(),
          );
        }

        final slivers = _buildSlivers(context, ref, feed);
        return PullToRefresh(
          scrollController: scrollController,
          onRefresh: () =>
              ref.read(newFeedProvider(feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.extentAfter <
                      notification.metrics.viewportDimension * 1.2) {
                ref.read(newFeedProvider(feedKey).notifier).loadMore();
              }
              return false;
            },
            child: SmoothWheelScroll(
              controller: scrollController,
              basePhysics: const AlwaysScrollableScrollPhysics(),
              builder: (context, controller, physics) => CustomScrollView(
                key: PageStorageKey(
                  'new-${feedKey.scope.name}-${feedKey.type.name}',
                ),
                controller: controller,
                physics: physics,
                scrollCacheExtent: kFeedCacheExtent,
                restorationId: 'new-${feedKey.scope.name}-${feedKey.type.name}',
                slivers: slivers,
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildSlivers(
    BuildContext context,
    WidgetRef ref,
    PagedFeedState feed,
  ) {
    final tail = <Widget>[
      if (feed.refreshPhase == FeedPhase.error)
        SliverToBoxAdapter(
          child: Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.lg,
              vertical: FuncSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(child: Text(context.l10n.newRefreshFailed)),
                TextButton(
                  onPressed: () =>
                      ref.read(newFeedProvider(feedKey).notifier).refresh(),
                  child: Text(context.l10n.newRetry),
                ),
              ],
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: FeedTail(
          feed: feed,
          onRetry: () =>
              ref.read(newFeedProvider(feedKey).notifier).retryLoadMore(),
          errorTitle: context.l10n.newLoadMoreFailed,
          retryLabel: context.l10n.newRetry,
        ),
      ),
      const SliverToBoxAdapter(child: FuncNavBarSpacer()),
    ];
    if (feedKey.type == NewFeedType.illust) {
      final store = ref.watch(illustStoreProvider);
      final entities = store.getAll(feed.ids);
      return [
        IllustFeedGrid(
          itemIds: [for (final e in entities) e.id],
          itemCount: entities.length,
          pagerLoadMore: () =>
              ref.read(newFeedProvider(feedKey).notifier).loadMore(),
          itemBuilder: (context, index) => IllustCard(
            entity: entities[index],
            heroScope: 'new:${feedKey.scope.name}:${feedKey.type.name}',
          ),
        ),
        ...tail,
      ];
    }
    final storedNovels = ref.watch(novelStoreProvider);
    final entities = [
      for (final id in feed.ids)
        if (storedNovels[id] != null) storedNovels[id]!,
    ];
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => NovelEntry.regular(entity: entities[index]),
          childCount: entities.length,
        ),
      ),
      ...tail,
    ];
  }
}

String _newText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
