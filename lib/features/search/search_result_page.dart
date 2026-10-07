import 'package:material_ui/material_ui.dart';

import '../../app/widgets/app_top_bar.dart';
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
import '../../core/settings/settings_controller.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_store.dart';
import '../../app/motion/state_fade.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../app/widgets/settings/persist_settings.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../app/widgets/skeleton/list_skeletons.dart';
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

/// Search results with the three result types as tabs. Each artwork type
/// owns its filter set for this search session — the page drafts are
/// seeded from the persisted defaults and the incoming URL (which always
/// describes the current type), so switching a tab picks up that type's
/// own set instead of carrying the previous tab's dimensions over.
class SearchResultPage extends ConsumerStatefulWidget {
  const SearchResultPage({super.key, required this.query, this.onTypeChanged});

  final SearchQuery query;

  /// Replaces the route with the query the page built for the selected
  /// type. Null for hosts without a result route of their own (the legacy
  /// tag page): the switch stays local to the page.
  final ValueChanged<SearchQuery>? onTypeChanged;

  @override
  ConsumerState<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends ConsumerState<SearchResultPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late SearchResultType _selectedType;
  final _scrollControllers = <SearchResultType, ScrollController>{};
  final _loadedTypes = <SearchResultType>{};

  /// Per-type filter drafts for this search session. Seeded from the
  /// persisted defaults, then the URL's own type overlays it — so a deep
  /// link's filter set wins and the other type falls back to the default.
  late IllustSearchFilters _illustFilters;
  late NovelSearchFilters _novelFilters;

  /// One body per type, reused across page builds while its query is
  /// unchanged — same reasoning as the ranking page's body cache.
  final _bodies = <SearchResultType, _SearchTabBody>{};

  /// A context inside the Scaffold's notification scope (see
  /// [announceTabScroll]).
  late BuildContext _notificationContext;

  SearchQuery _queryFor(SearchResultType type) => searchQueryForType(
    type,
    keyword: widget.query.keyword,
    illustFilters: _illustFilters,
    novelFilters: _novelFilters,
  );

  SearchFilters _filtersFor(SearchResultType type) => switch (type) {
    SearchResultType.illust => _illustFilters,
    SearchResultType.novel => _novelFilters,
    // User results have no filters — the sheet and summary bar are never
    // shown for it (showFilters guards both entry points).
    SearchResultType.user => _illustFilters,
  };

  /// The URL is the source of truth for its own type — deep links,
  /// restored sessions and external replaces overwrite that type's draft.
  void _acceptQueryFilters(SearchQuery query) {
    switch (query) {
      case IllustSearchQuery(:final filters):
        _illustFilters = filters;
      case NovelSearchQuery(:final filters):
        _novelFilters = filters;
      case UserSearchQuery():
    }
  }

  @override
  void initState() {
    super.initState();
    _illustFilters = ref.read(searchIllustFiltersProvider);
    _novelFilters = ref.read(searchNovelFiltersProvider);
    _acceptQueryFilters(widget.query);
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
    _acceptQueryFilters(widget.query);
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
    widget.onTypeChanged?.call(_queryFor(type));
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
    final query = _queryFor(type);
    final cached = _bodies[type];
    if (cached != null && cached.query == query) return cached;
    return _bodies[type] = _SearchTabBody(
      key: ValueKey(type),
      query: query,
      scrollController: _scrollControllerFor(type),
    );
  }

  /// Applies [filters] to the tab on screen and records it in the route —
  /// the URL always describes the current type's set.
  void _replaceFilters(SearchFilters filters) {
    setState(() {
      switch (filters) {
        case final IllustSearchFilters f:
          _illustFilters = f;
        case final NovelSearchFilters f:
          _novelFilters = f;
      }
    });
    replaceSearchResults(context, _queryFor(_selectedType));
  }

  Future<void> _editFilters() async {
    final result = await showSearchFilterSheet(
      context,
      initial: _filtersFor(_selectedType),
      offerSetDefault: true,
    );
    if (!mounted || result == null) return;
    if (result.makeDefault) {
      // persistSettings surfaces a write failure as a snackbar; the
      // session apply below still runs — it is the button's primary job.
      await persistSettings(
        context,
        () => ref
            .read(settingsProvider.notifier)
            .setSearchFilters(result.filters),
      );
      if (!mounted) return;
    }
    _replaceFilters(result.filters);
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
      appBar: AppTopBar(
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
                  filters: _filtersFor(_selectedType),
                  onEdit: _editFilters,
                  // Clearing resets this tab to its type's empty set —
                  // the persisted defaults stay untouched.
                  onClear: () => _replaceFilters(
                    _selectedType == SearchResultType.novel
                        ? NovelSearchFilters.defaults
                        : IllustSearchFilters.defaults,
                  ),
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
    final body = _body(context, ref);
    return StateFade(kind: body is _SearchLoading, child: body);
  }

  Widget _body(BuildContext context, WidgetRef ref) {
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
    NovelSearchQuery() => NovelListSkeleton(label: context.l10n.searchLoading),
    UserSearchQuery() => UserListSkeleton(label: context.l10n.searchLoading),
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
            : Text(
                context.l10n.labelValue(
                  context.l10n.searchUserAccount,
                  user.account,
                ),
              ),
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
      if (filters.normalizedTarget != SearchTarget.partialMatchForTags)
        searchText(context, filters.normalizedTarget.labelKey),
      if (filters.normalizedSort != SearchSort.dateDesc)
        searchText(context, filters.normalizedSort.labelKey),
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
      // Each type only displays its own dimensions.
      ...switch (filters) {
        final IllustSearchFilters f => [
          if (f.ratio != null) searchText(context, f.ratio!.labelKey),
          if (f.contentType != SearchContentType.illustAndMangaAndUgoira)
            searchText(context, f.contentType.labelKey),
          ?_rangeLabel(
            context,
            l10n.searchWidth,
            f.widthMin,
            f.widthMax,
            pixels,
          ),
          ?_rangeLabel(
            context,
            l10n.searchHeight,
            f.heightMin,
            f.heightMax,
            pixels,
          ),
        ],
        final NovelSearchFilters f => [
          ?_rangeLabel(
            context,
            l10n.searchTextLength,
            f.textLengthMin,
            f.textLengthMax,
            pixels,
          ),
          if (f.originalOnly) l10n.searchOriginalOnly,
        ],
      },
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
