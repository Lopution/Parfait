import 'package:material_ui/material_ui.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/novel_card.dart';
import '../../core/entity/illust_store.dart';
import '../../core/new/new_feed_controller.dart';
import '../../core/new/new_feed_models.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/branch_slide_stack.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/root_swipe_switcher.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';

/// Beta56 New page: scope tabs + a persistent content-type selector. Both
/// are route-durable (`/new?scope=&type=`): [initialScope]/[initialType]
/// seed the controller and tab/chip changes echo back through
/// [onFeedChanged]. Each (scope, type) pair keeps its own feed state,
/// scroll offset and cursor — switching back does not refetch.
class NewPage extends StatefulWidget {
  const NewPage({
    super.key,
    this.initialScope = NewFeedScope.following,
    this.initialType = NewFeedType.illust,
    this.onFeedChanged,
  });

  final NewFeedScope initialScope;
  final NewFeedType initialType;
  final void Function(NewFeedScope scope, NewFeedType type)? onFeedChanged;

  @override
  State<NewPage> createState() => _NewPageState();
}

class _NewPageState extends State<NewPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _loadedKeys = <NewFeedKey>{};
  final _scrollControllers = <NewFeedKey, ScrollController>{};
  late int _selectedIndex;
  late NewFeedType _type;
  bool _suppressRouteEcho = false;
  ReTapChannel? _reTapChannel;

  static const _scopes = NewFeedScope.values;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _scopes.indexOf(widget.initialScope);
    _type = widget.initialType;
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
    final channel = BranchSlideStack.maybeOf(context)?.reTapEvents;
    if (identical(channel, _reTapChannel)) return;
    _reTapChannel?.removeListener(_onBranchReTap);
    _reTapChannel = channel;
    _reTapChannel?.addListener(_onBranchReTap);
  }

  @override
  void didUpdateWidget(NewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page key, so a route write lands here as a
    // widget update. Self-echoes carry the current values and no-op; only
    // an externally changed param moves the strip — the controller is
    // never reset.
    if (widget.initialScope == _scopes[_selectedIndex] &&
        widget.initialType == _type) {
      return;
    }
    setState(() {
      _type = widget.initialType;
      _loadedKeys.add(NewFeedKey(scope: widget.initialScope, type: _type));
    });
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

  NewFeedKey get _activeKey =>
      NewFeedKey(scope: _scopes[_selectedIndex], type: _type);

  ScrollController _scrollControllerFor(NewFeedKey key) =>
      _scrollControllers.putIfAbsent(key, ScrollController.new);

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex) return;
    setState(() {
      _selectedIndex = _tabController.index;
      _loadedKeys.add(_activeKey);
    });
    if (!_suppressRouteEcho) {
      widget.onFeedChanged?.call(_scopes[_selectedIndex], _type);
    }
  }

  void _onTabTap(int index) {
    // A same-index scope tap scrolls the visible feed to top — it never
    // toggles the type selector, refreshes, or changes selection.
    if (index == _selectedIndex && !_tabController.indexIsChanging) {
      reTapScrollToTop(context, _scrollControllerFor(_activeKey));
    }
  }

  void _onTypeSelected(NewFeedType type) {
    if (type == _type) {
      // Same-index type tap: pure scroll-to-top, same as a scope re-tap.
      reTapScrollToTop(context, _scrollControllerFor(_activeKey));
      return;
    }
    setState(() {
      _type = type;
      _loadedKeys.add(_activeKey);
    });
    widget.onFeedChanged?.call(_scopes[_selectedIndex], type);
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
      appBar: AppBar(
        titleSpacing: 0,
        title: TabBar(
          controller: _tabController,
          // Scrollable instead of equal-width slots + FittedBox: labels
          // stay at full size in every locale (long translations used to
          // shrink to unreadable).
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: 5),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          onTap: _onTabTap,
          tabs: [
            for (final scope in _scopes)
              Tab(text: _newText(context, _scopeLabelKey(scope))),
          ],
        ),
        // Feature entries (watchlist, local novels) live in settings'
        // content group — the three home feeds keep identical chrome:
        // AppBar + embedded TabBar, no stray action icons.
      ),
      body: RootSwipeSwitcher(
        tabController: _tabController,
        // A neighbor the finger is about to uncover has to exist before
        // the slide starts — same offscreen-page warmup ViewPager does.
        onPrepareAdjacent: (index) => setState(() {
          for (final i in [index - 1, index + 1]) {
            if (i >= 0 && i < _scopes.length) {
              _loadedKeys.add(NewFeedKey(scope: _scopes[i], type: _type));
            }
          }
        }),
        child: Column(
          children: [
            // The type selector is persistent chrome — the query context
            // (scope × type) stays visible in every feed state.
            _NewTypeSelector(type: _type, onChanged: _onTypeSelected),
            Expanded(
              child: TabSlideStack(
                controller: _tabController,
                children: [
                  for (final scope in _scopes)
                    // Each scope slot keeps its own loaded type bodies —
                    // same per-key state preservation as the old flat
                    // Offstage stack, now arranged along the strip axis.
                    Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final key in _loadedKeys)
                          if (key.scope == scope)
                            Offstage(
                              offstage: key.type != _type,
                              child: _NewFeedBody(
                                key: ValueKey(key),
                                feedKey: key,
                                scrollController: _scrollControllerFor(key),
                              ),
                            ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _scopeLabelKey(NewFeedScope scope) => switch (scope) {
    NewFeedScope.following => 'newFollowing',
    NewFeedScope.everyone => 'newEveryone',
    NewFeedScope.myPixiv => 'newMyPixiv',
  };
}

class _NewTypeSelector extends StatelessWidget {
  const _NewTypeSelector({required this.type, required this.onChanged});

  final NewFeedType type;
  final ValueChanged<NewFeedType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        height: 64,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in NewFeedType.values) ...[
                if (value != NewFeedType.values.first) const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(
                    _newText(
                      context,
                      value == NewFeedType.illust ? 'newIllust' : 'newNovel',
                    ),
                  ),
                  selected: value == type,
                  onSelected: (_) => onChanged(value),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One keyed feed body. The state is kept alive by [NewPage]'s Offstage stack
/// so scroll/cursor/error state is not shared with another scope or type.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(newFeedProvider(feedKey));
    return feedAsync.when(
      loading: () => FeedEmpty(
        icon: Icons.fiber_new_outlined,
        title: context.l10n.newLoading,
      ),
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
        if (feed.showInitialSpinner) {
          return FeedEmpty(
            icon: Icons.fiber_new_outlined,
            title: context.l10n.newLoading,
          );
        }
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            icon: Icons.inbox_outlined,
            title: context.l10n.newEmpty,
            retryLabel: context.l10n.newRetry,
            onRefresh: () =>
                ref.read(newFeedProvider(feedKey).notifier).refresh(),
          );
        }

        final slivers = _buildSlivers(context, ref, feed);
        return PullToRefresh(
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
          padding: const EdgeInsets.symmetric(horizontal: 10),
          mainAxisSpacing: 5,
          crossAxisSpacing: 10,
          prefetchEntities: entities,
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
          (context, index) => NovelCard(entity: entities[index]),
          childCount: entities.length,
        ),
      ),
      ...tail,
    ];
  }
}

String _newText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
