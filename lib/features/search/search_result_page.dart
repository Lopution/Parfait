import 'package:material_ui/material_ui.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/person_avatar.dart';
import '../../app/widgets/novel_card.dart';
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
import '../../l10n/context.dart';

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
    final selected = await showSearchFilterSheet(context, initial: filters);
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(searchFeedProvider(query));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          query.keyword.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
            return FeedEmpty(icon: Icons.search, title: context.l10n.searchLoading);
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
      );
    }
    return PullToRefresh(
      onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 400) {
            ref.read(searchFeedProvider(query).notifier).loadMore();
          }
          return false;
        },
        child: CustomScrollView(
          key: PageStorageKey(query.cacheKey),
          physics: const AlwaysScrollableScrollPhysics(),
          restorationId: 'search-${query.cacheKey}',
          slivers: [
            IllustFeedGrid(
  padding: const EdgeInsets.all(10),
  mainAxisSpacing: 5,
  crossAxisSpacing: 10,
  itemCount: entities.length,
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
      );
    }
    return PullToRefresh(
      onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 400) {
            ref.read(searchFeedProvider(query).notifier).loadMore();
          }
          return false;
        },
        child: ListView.builder(
          key: PageStorageKey(query.cacheKey),
          physics: const AlwaysScrollableScrollPhysics(),
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
            return NovelCard(entity: entities[index]);
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
      );
    }
    return PullToRefresh(
      onRefresh: () => ref.read(searchFeedProvider(query).notifier).refresh(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 400) {
            ref.read(searchFeedProvider(query).notifier).loadMore();
          }
          return false;
        },
        child: ListView.builder(
          key: PageStorageKey(query.cacheKey),
          physics: const AlwaysScrollableScrollPhysics(),
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
            : Text(
                '${context.l10n.searchUserAccount}: ${user.account}',
              ),
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
