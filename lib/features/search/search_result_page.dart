import 'package:material_ui/material_ui.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../app/navigation/routes.dart';
import 'search_filter_sheet.dart';
import 'search_text.dart';
import '../../l10n/context.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';

class SearchResultPage extends ConsumerWidget {
  const SearchResultPage({super.key, required this.query});

  final SearchQuery query;

  SearchFilters? get _filters => switch (query) {
    IllustSearchQuery(:final filters) => filters,
    NovelSearchQuery(:final filters) => filters,
    UserSearchQuery() => null,
  };

  Future<void> _editFilters(BuildContext context) async {
    final filters = _filters;
    if (filters == null) return;
    final selected = await showSearchFilterSheet(
      context,
      initial: filters,
      type: query.type,
    );
    if (!context.mounted || selected == null) return;
    final updated = switch (query) {
      IllustSearchQuery() => (query as IllustSearchQuery).copyWith(
        filters: selected,
      ),
      NovelSearchQuery() => (query as NovelSearchQuery).copyWith(
        filters: selected,
      ),
      UserSearchQuery() => query,
    };
    replaceSearchResults(context, updated);
  }

  /// The result-page header keeps "what am I looking at" live: tapping the
  /// keyword reopens the input page prefilled with this query so editing a
  /// search never means retyping it.
  void _editQuery(BuildContext context) {
    openSearchInput(context, initialKeyword: query.keyword, type: query.type);
  }

  void _clearFilters(BuildContext context) {
    final updated = switch (query) {
      IllustSearchQuery() => (query as IllustSearchQuery).copyWith(
        filters: SearchFilters.defaults,
      ),
      NovelSearchQuery() => (query as NovelSearchQuery).copyWith(
        filters: SearchFilters.defaults,
      ),
      UserSearchQuery() => query,
    };
    replaceSearchResults(context, updated);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(searchFeedProvider(query));
    final filters = _filters;
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
            borderRadius: BorderRadius.circular(8),
            onTap: () => _editQuery(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      query.keyword.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
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
        bottom: filters == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(44),
                child: _FilterSummaryBar(
                  filters: filters,
                  onEdit: () => _editFilters(context),
                  onClear: () => _clearFilters(context),
                ),
              ),
        actions: [
          if (_filters != null)
            IconButton(
              tooltip: context.l10n.searchFilters,
              onPressed: () => _editFilters(context),
              icon: const Icon(Icons.tune),
            ),
        ],
      ),
      body: async.when(
        loading: () =>
            FeedEmpty(icon: Icons.search, title: context.l10n.searchLoading),
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
              error: feed.initialError ?? const ApiParseError('unknown error'),
              retryLabel: context.l10n.searchRetry,
              onRetry: () =>
                  ref.read(searchFeedProvider(query).notifier).retryInitial(),
            );
          }
          if (feed.showInitialSpinner) {
            return FeedEmpty(
              icon: Icons.search,
              title: context.l10n.searchLoading,
            );
          }
          return _SearchFeedContent(query: query, feed: feed);
        },
      ),
    );
  }
}

class _SearchFeedContent extends ConsumerWidget {
  const _SearchFeedContent({required this.query, required this.feed});

  final SearchQuery query;
  final PagedFeedState feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (query) {
      IllustSearchQuery() => _IllustSearchFeed(query: query, feed: feed),
      NovelSearchQuery() => _NovelSearchFeed(query: query, feed: feed),
      UserSearchQuery() => _UserSearchFeed(query: query, feed: feed),
    };
  }
}

class _IllustSearchFeed extends ConsumerWidget {
  const _IllustSearchFeed({required this.query, required this.feed});

  final SearchQuery query;
  final PagedFeedState feed;

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
          basePhysics: const AlwaysScrollableScrollPhysics(),
          builder: (context, controller, physics) => CustomScrollView(
            key: PageStorageKey(query.cacheKey),
            physics: physics,
            scrollCacheExtent: kFeedCacheExtent,
            restorationId: 'search-${query.cacheKey}',
            controller: controller,
            slivers: [
              IllustFeedGrid(
                padding: const EdgeInsets.all(10),
                mainAxisSpacing: 5,
                crossAxisSpacing: 10,
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
  const _NovelSearchFeed({required this.query, required this.feed});

  final SearchQuery query;
  final PagedFeedState feed;

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
  const _UserSearchFeed({required this.query, required this.feed});

  final SearchQuery query;
  final PagedFeedState feed;

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
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        onTap: () => openUser(context, user.id),
        leading: PersonAvatar(imageUrl: user.profileImageUrl, radius: 26),
        title: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: user.account.isEmpty
            ? null
            : Text('${context.l10n.searchUserAccount}: ${user.account}'),
        trailing: FollowSwitchButton(
          userId: user.id,
          userName: user.name,
          userAccount: user.account,
          compact: true,
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

  String _dateText(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  List<String> _activeLabels(BuildContext context) {
    final l10n = context.l10n;
    final labels = <String>[
      if (filters.target != SearchTarget.partialMatchForTags)
        searchText(context, filters.target.labelKey),
      if (filters.sort != SearchSort.dateDesc)
        searchText(context, filters.sort.labelKey),
      if (filters.duration != null)
        searchText(context, filters.duration!.labelKey),
      if (filters.startDate != null || filters.endDate != null)
        '${filters.startDate == null ? '…' : _dateText(filters.startDate!)}'
            ' – ${filters.endDate == null ? '…' : _dateText(filters.endDate!)}',
      if (filters.aiFilter != SearchAiFilter.all)
        searchText(context, filters.aiFilter.labelKey),
      if (filters.bookmarkMin != null || filters.bookmarkMax != null)
        '♥ ${filters.bookmarkMin ?? 0} – ${filters.bookmarkMax ?? '∞'}',
      if (filters.ratio != null) searchText(context, filters.ratio!.labelKey),
      if (filters.contentType != SearchContentType.illustAndMangaAndUgoira)
        searchText(context, filters.contentType.labelKey),
      if (filters.widthMin != null || filters.widthMax != null)
        '${l10n.searchWidth} '
            '${filters.widthMin ?? 0} – ${filters.widthMax ?? '∞'}',
      if (filters.heightMin != null || filters.heightMax != null)
        '${l10n.searchHeight} '
            '${filters.heightMin ?? 0} – ${filters.heightMax ?? '∞'}',
    ];
    return labels;
  }

  @override
  Widget build(BuildContext context) {
    final labels = _activeLabels(context);
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                const SizedBox(width: 8),
              ],
            const SizedBox(width: 4),
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
