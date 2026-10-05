import 'package:material_ui/material_ui.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../app/person_avatar.dart';
import '../../app/widgets/novel_entry.dart';
import '../../app/pull_to_refresh.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/search/search_feed_controller.dart';
import '../../core/search/search_models.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_store.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../app/navigation/routes.dart';
import 'search_filter_sheet.dart';
import 'search_text.dart';
import '../../l10n/context.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// Grid padding shared by the result sliver and its first-load skeleton.
const _illustGridPadding = EdgeInsets.all(FuncSpacing.sm);

/// Height of the filter summary row under the type tabs.
const _filterBarHeight = 44.0;

/// Search results with the three result types as tabs. Switching a tab
/// keeps the keyword and filters ([SearchQuery.withType]); the route only
/// records the switch through [onTypeChanged].
class SearchResultPage extends StatefulWidget {
  const SearchResultPage({super.key, required this.query, this.onTypeChanged});

  final SearchQuery query;

  /// Replaces the route with the switched query. Null for hosts without a
  /// result route of their own (the legacy tag page): the switch stays
  /// local to the page.
  final ValueChanged<SearchResultType>? onTypeChanged;

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<SearchResultPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late SearchResultType _selectedType;
  final _scrollControllers = <SearchResultType, ScrollController>{};
  final _loadedTypes = <SearchResultType>{};

  /// One body per type, reused across page builds while its query is
  /// unchanged — same reasoning as the ranking page's body cache.
  final _bodies = <SearchResultType, _SearchTabBody>{};

  /// A context inside the Scaffold's notification scope (see
  /// [announceTabScroll]).
  late BuildContext _notificationContext;

  SearchQuery get _activeQuery => widget.query.withType(_selectedType);

  @override
  void initState() {
    super.initState();
    _selectedType = widget.query.type;
    _loadedTypes.add(_selectedType);
    _tabController = TabController(
      length: SearchResultType.values.length,
      vsync: this,
      initialIndex: _selectedType.index,
    )..addListener(_handleTabChanged);
  }

  @override
  void didUpdateWidget(SearchResultPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final type = widget.query.type;
    if (type == _selectedType) return;
    // The route changed type from outside a tab tap: follow it without an
    // animation. The listener sees the type already selected and stays
    // quiet, so the route is not replaced a second time.
    _selectedType = type;
    _loadedTypes.add(type);
    _tabController.index = type.index;
    announceTabScroll(_notificationContext, _scrollControllerFor(type));
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
    final type = SearchResultType.values[_tabController.index];
    if (type == _selectedType) return;
    setState(() {
      _selectedType = type;
      _loadedTypes.add(type);
    });
    announceTabScroll(_notificationContext, _scrollControllerFor(type));
    widget.onTypeChanged?.call(type);
  }

  ScrollController _scrollControllerFor(SearchResultType type) {
    return _scrollControllers.putIfAbsent(
      type,
      () => ScrollController(
        onAttach: (_) {
          // A first-visited tab's list mounts after the tab-change
          // announce has already fired.
          if (type == _selectedType) {
            announceTabScroll(_notificationContext, _scrollControllers[type]!);
          }
        },
      ),
    );
  }

  void _prepareAdjacent(int index) {
    final types = SearchResultType.values;
    final last = types.length - 1;
    final neighbours = {
      types[(index - 1).clamp(0, last)],
      types[(index + 1).clamp(0, last)],
    };
    if (_loadedTypes.containsAll(neighbours)) return;
    setState(() => _loadedTypes.addAll(neighbours));
  }

  _SearchTabBody _bodyFor(SearchResultType type) {
    final query = widget.query.withType(type);
    final cached = _bodies[type];
    if (cached != null && cached.query == query) return cached;
    return _bodies[type] = _SearchTabBody(
      key: ValueKey(type),
      query: query,
      scrollController: _scrollControllerFor(type),
    );
  }

  /// Applies [filters] to the tab on screen and records it in the route.
  void _replaceFilters(SearchFilters filters) {
    replaceSearchResults(
      context,
      IllustSearchQuery(
        keyword: widget.query.keyword,
        filters: filters,
      ).withType(_selectedType),
    );
  }

  Future<void> _editFilters() async {
    final selected = await showSearchFilterSheet(
      context,
      initial: _activeQuery.carriedFilters,
      type: _selectedType,
    );
    if (!mounted || selected == null) return;
    _replaceFilters(selected);
  }

  /// The result-page header keeps "what am I looking at" live: tapping the
  /// keyword reopens the input page prefilled with this query so editing a
  /// search never means retyping it.
  void _editQuery() {
    openSearchInput(
      context,
      initialKeyword: widget.query.keyword,
      type: _selectedType,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The user tab has no filters: the bar goes away and the app bar gets
    // shorter.
    final showFilters = _selectedType != SearchResultType.user;
    final tabBar = AppTabBar(
      controller: _tabController,
      onTap: (index) {
        // A same-index tap leaves indexIsChanging false: scroll the
        // current tab to top, nothing else.
        if (!_tabController.indexIsChanging) {
          reTapScrollToTop(
            context,
            _scrollControllerFor(SearchResultType.values[index]),
          );
        }
      },
      labels: [
        for (final type in SearchResultType.values)
          searchText(context, type.labelKey),
      ],
    );
    return Scaffold(
      // No inline composer: a `true` here would subscribe this page (and
      // every live branch page) to per-frame viewInsets churn while the
      // IME hides during the push transition — the constant-low-FPS
      // search-suggestion push came from that relayout storm.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 0,
        title: Tooltip(
          message: context.l10n.searchModifyQuery,
          child: InkWell(
            borderRadius: FuncShape.control,
            onTap: _editQuery,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FuncSpacing.xs,
                vertical: FuncSpacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.query.keyword.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.xs),
                  Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        // The summary row is persistent context (visible in
        // loading/error/empty alike): one chip per active filter, tapping
        // any chip opens the sheet, the clear entry stays on the row even
        // when nothing is active so its affordance never moves.
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            tabBar.preferredSize.height + (showFilters ? _filterBarHeight : 0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tabBar,
              if (showFilters)
                _FilterSummaryBar(
                  filters: _activeQuery.carriedFilters,
                  onEdit: _editFilters,
                  onClear: () => _replaceFilters(SearchFilters.defaults),
                ),
            ],
          ),
        ),
        actions: [
          if (showFilters)
            IconButton(
              tooltip: context.l10n.searchFilters,
              onPressed: _editFilters,
              icon: const Icon(Icons.tune),
            ),
        ],
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          return TabSwipeSwitcher(
            tabController: _tabController,
            onPrepareAdjacent: _prepareAdjacent,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final type in SearchResultType.values)
                  if (_loadedTypes.contains(type))
                    _bodyFor(type)
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

/// One result tab: loading, error and the feed for [query].
class _SearchTabBody extends ConsumerWidget {
  const _SearchTabBody({
    super.key,
    required this.query,
    required this.scrollController,
  });

  final SearchQuery query;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(searchFeedProvider(query))
        .when(
          loading: () => _SearchLoading(query: query),
          error: (error, _) => FeedError(
            title: context.l10n.searchLoadFailed,
            error: error,
            retryLabel: context.l10n.searchRetry,
            onRetry: () => ref.invalidate(searchFeedProvider(query)),
          ),
          data: (feed) {
            if (feed.showInitialError) {
              return FeedError(
                title: context.l10n.searchLoadFailed,
                error:
                    feed.initialError ?? const ApiParseError('unknown error'),
                retryLabel: context.l10n.searchRetry,
                onRetry: () =>
                    ref.read(searchFeedProvider(query).notifier).retryInitial(),
              );
            }
            if (feed.showInitialSpinner) return _SearchLoading(query: query);
            return switch (query) {
              IllustSearchQuery() => _IllustSearchFeed(
                query: query,
                feed: feed,
                scrollController: scrollController,
              ),
              NovelSearchQuery() => _NovelSearchFeed(
                query: query,
                feed: feed,
                scrollController: scrollController,
              ),
              UserSearchQuery() => _UserSearchFeed(
                query: query,
                feed: feed,
                scrollController: scrollController,
              ),
            };
          },
        );
  }
}

class _SearchLoading extends StatelessWidget {
  const _SearchLoading({required this.query});

  final SearchQuery query;

  @override
  Widget build(BuildContext context) => switch (query) {
    IllustSearchQuery() => IllustGridSkeleton(
      label: context.l10n.searchLoading,
      padding: _illustGridPadding,
    ),
    _ => FeedLoading(label: context.l10n.searchLoading),
  };
}

class _IllustSearchFeed extends ConsumerWidget {
  const _IllustSearchFeed({
    required this.query,
    required this.feed,
    required this.scrollController,
  });

  final SearchQuery query;
  final PagedFeedState feed;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entities = ref.watch(illustStoreProvider).getAll(feed.ids);
    if (entities.isEmpty) {
      return FeedEmpty(
        icon: Icons.search,
        title: context.l10n.searchNoResults,
        retryLabel: context.l10n.searchRetry,
        onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
        actionLabel: context.l10n.searchModifyQuery,
        onAction: () => openSearchInput(
          context,
          initialKeyword: query.keyword,
          type: query.type,
        ),
      );
    }
    return PullToRefresh(
      onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter <
                  notification.metrics.viewportDimension * 1.2) {
            ref.read(searchFeedProvider(query).notifier).loadMore();
          }
          return false;
        },
        child: SmoothWheelScroll(
          controller: scrollController,
          basePhysics: const AlwaysScrollableScrollPhysics(),
          builder: (context, controller, physics) => CustomScrollView(
            key: PageStorageKey(query.cacheKey),
            physics: physics,
            scrollCacheExtent: kFeedCacheExtent,
            restorationId: 'search-${query.cacheKey}',
            controller: controller,
            slivers: [
              IllustFeedGrid(
                padding: _illustGridPadding,
                prefetchEntities: entities,
                itemIds: [for (final e in entities) e.id],
                itemCount: entities.length,
                pagerLoadMore: () =>
                    ref.read(searchFeedProvider(query).notifier).loadMore(),
                itemBuilder: (context, index) => IllustCard(
                  entity: entities[index],
                  heroScope: 'search:${query.cacheKey}',
                ),
              ),
              SliverToBoxAdapter(
                child: FeedTail(
                  feed: feed,
                  onRetry: () => ref
                      .read(searchFeedProvider(query).notifier)
                      .retryLoadMore(),
                  errorTitle: context.l10n.searchLoadMoreFailed,
                  retryLabel: context.l10n.searchRetry,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NovelSearchFeed extends ConsumerWidget {
  const _NovelSearchFeed({
    required this.query,
    required this.feed,
    required this.scrollController,
  });

  final SearchQuery query;
  final PagedFeedState feed;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stored = ref.watch(novelStoreProvider);
    final entities = [
      for (final id in feed.ids)
        if (stored[id] != null) stored[id]!,
    ];
    if (entities.isEmpty) {
      return FeedEmpty(
        icon: Icons.search,
        title: context.l10n.searchNoResults,
        retryLabel: context.l10n.searchRetry,
        onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
        actionLabel: context.l10n.searchModifyQuery,
        onAction: () => openSearchInput(
          context,
          initialKeyword: query.keyword,
          type: query.type,
        ),
      );
    }
    return PullToRefresh(
      onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter <
                  notification.metrics.viewportDimension * 1.2) {
            ref.read(searchFeedProvider(query).notifier).loadMore();
          }
          return false;
        },
        child: ListView.builder(
          key: PageStorageKey(query.cacheKey),
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          scrollCacheExtent: kFeedCacheExtent,
          restorationId: 'search-${query.cacheKey}',
          itemCount: entities.length + 1,
          itemBuilder: (context, index) {
            if (index == entities.length) {
              return FeedTail(
                feed: feed,
                onRetry: () => ref
                    .read(searchFeedProvider(query).notifier)
                    .retryLoadMore(),
                errorTitle: context.l10n.searchLoadMoreFailed,
                retryLabel: context.l10n.searchRetry,
              );
            }
            return NovelEntry.regular(entity: entities[index]);
          },
        ),
      ),
    );
  }
}

class _UserSearchFeed extends ConsumerWidget {
  const _UserSearchFeed({
    required this.query,
    required this.feed,
    required this.scrollController,
  });

  final SearchQuery query;
  final PagedFeedState feed;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stored = ref.watch(userStoreProvider);
    final users = [
      for (final id in feed.ids)
        if (stored[id] != null) stored[id]!,
    ];
    if (users.isEmpty) {
      return FeedEmpty(
        icon: Icons.search,
        title: context.l10n.searchNoResults,
        retryLabel: context.l10n.searchRetry,
        onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
        actionLabel: context.l10n.searchModifyQuery,
        onAction: () => openSearchInput(
          context,
          initialKeyword: query.keyword,
          type: query.type,
        ),
      );
    }
    return PullToRefresh(
      onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter <
                  notification.metrics.viewportDimension * 1.2) {
            ref.read(searchFeedProvider(query).notifier).loadMore();
          }
          return false;
        },
        child: ListView.builder(
          key: PageStorageKey(query.cacheKey),
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          scrollCacheExtent: kFeedCacheExtent,
          restorationId: 'search-${query.cacheKey}',
          itemCount: users.length + 1,
          itemBuilder: (context, index) {
            if (index == users.length) {
              return FeedTail(
                feed: feed,
                onRetry: () => ref
                    .read(searchFeedProvider(query).notifier)
                    .retryLoadMore(),
                errorTitle: context.l10n.searchLoadMoreFailed,
                retryLabel: context.l10n.searchRetry,
              );
            }
            return _SearchUserTile(user: users[index]);
          },
        ),
      ),
    );
  }
}

class _SearchUserTile extends StatelessWidget {
  const _SearchUserTile({required this.user});

  final UserEntity user;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.md,
        vertical: FuncSpacing.sm,
      ),
      child: ListTile(
        onTap: () => openUser(context, user.id),
        leading: PersonAvatar(imageUrl: user.profileImageUrl, radius: 26),
        title: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: user.account.isEmpty
            ? null
            : Text('${context.l10n.searchUserAccount}: ${user.account}'),
        // ListTile asserts when the trailing widget consumes the entire
        // tile width, so an oversized localized button is capped at half
        // the row to leave the title a lane; the button scales its label
        // down past that bound.
        trailing: LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.5),
            child: FollowSwitchButton(
              userId: user.id,
              userName: user.name,
              userAccount: user.account,
              compact: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// Persistent filter context under the result-page title: one chip per
/// non-default field plus a clear entry. Tapping any chip reopens the
/// sheet; clearing replaces the route with default filters so the URL
/// keeps describing exactly what the user sees.
class _FilterSummaryBar extends StatelessWidget {
  const _FilterSummaryBar({
    required this.filters,
    required this.onEdit,
    required this.onClear,
  });

  final SearchFilters filters;
  final VoidCallback onEdit;
  final VoidCallback onClear;

  String? _dateLabel(BuildContext context) {
    final l10n = context.l10n;
    final start = filters.startDate == null
        ? null
        : AppFormat.date(context, filters.startDate!);
    final end = filters.endDate == null
        ? null
        : AppFormat.date(context, filters.endDate!);
    return switch ((start, end)) {
      (null, null) => null,
      (final start?, null) => l10n.searchDateFrom(start),
      (null, final end?) => l10n.searchDateUntil(end),
      (final start?, final end?) => l10n.searchDateBetween(start, end),
    };
  }

  /// One bounded filter as "label, bound(s)"; null when neither bound is
  /// set. [format] renders a bound (compact counts or raw pixels).
  static String? _rangeLabel(
    BuildContext context,
    String label,
    int? min,
    int? max,
    String Function(int value) format,
  ) {
    final l10n = context.l10n;
    return switch ((min, max)) {
      (null, null) => null,
      (final min?, null) => l10n.searchRangeAtLeast(label, format(min)),
      (null, final max?) => l10n.searchRangeAtMost(label, format(max)),
      (final min?, final max?) => l10n.searchRangeBetween(
        label,
        format(min),
        format(max),
      ),
    };
  }

  List<String> _activeLabels(BuildContext context) {
    final l10n = context.l10n;
    String pixels(int value) => '$value';
    return [
      if (filters.target != SearchTarget.partialMatchForTags)
        searchText(context, filters.target.labelKey),
      if (filters.sort != SearchSort.dateDesc)
        searchText(context, filters.sort.labelKey),
      if (filters.duration != null)
        searchText(context, filters.duration!.labelKey),
      ?_dateLabel(context),
      if (filters.aiFilter != SearchAiFilter.all)
        searchText(context, filters.aiFilter.labelKey),
      ?_rangeLabel(
        context,
        l10n.searchBookmarkSection,
        filters.bookmarkMin,
        filters.bookmarkMax,
        (value) => AppFormat.count(context, value),
      ),
      if (filters.ratio != null) searchText(context, filters.ratio!.labelKey),
      if (filters.contentType != SearchContentType.illustAndMangaAndUgoira)
        searchText(context, filters.contentType.labelKey),
      ?_rangeLabel(
        context,
        l10n.searchWidth,
        filters.widthMin,
        filters.widthMax,
        pixels,
      ),
      ?_rangeLabel(
        context,
        l10n.searchHeight,
        filters.heightMin,
        filters.heightMax,
        pixels,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final labels = _activeLabels(context);
    return SizedBox(
      height: _filterBarHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          FuncSpacing.lg,
          0,
          FuncSpacing.lg,
          FuncSpacing.sm,
        ),
        child: Row(
          children: [
            if (labels.isEmpty)
              ActionChip(
                avatar: const Icon(Icons.tune, size: 16),
                label: Text(context.l10n.searchFilters),
                onPressed: onEdit,
              )
            else
              for (final label in labels) ...[
                ActionChip(label: Text(label), onPressed: onEdit),
                const SizedBox(width: FuncSpacing.sm),
              ],
            const SizedBox(width: FuncSpacing.xs),
            ActionChip(
              avatar: const Icon(Icons.filter_alt_off_outlined, size: 16),
              label: Text(context.l10n.searchReset),
              onPressed: labels.isEmpty ? null : onClear,
            ),
          ],
        ),
      ),
    );
  }
}
