import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app/pixiv_image.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/replica_page_route.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/search/search_feed_controller.dart';
import '../../core/search/search_models.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_store.dart';
import '../home/recommended/recommended_illust_page.dart';
import '../novel/novel_page.dart';
import '../profile/follow_switch_button.dart';
import '../profile/user_page.dart';
import 'search_filter_sheet.dart';
import 'search_text.dart';

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
    Navigator.of(context).pushReplacement(
      ReplicaPageRoute<void>(builder: (_) => SearchResultPage(query: updated)),
    );
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
              tooltip: searchText(context, 'searchFilters'),
              onPressed: () => _editFilters(context),
              icon: const Icon(Icons.tune),
            ),
        ],
      ),
      body: async.when(
        loading: () =>
            _SearchStatus(title: searchText(context, 'searchLoading')),
        error: (error, _) => _SearchResultError(
          error: error,
          onRetry: () => ref.invalidate(searchFeedProvider(query)),
        ),
        data: (feed) {
          if (feed.showInitialError) {
            return _SearchResultError(
              error: feed.initialError ?? const ApiParseError('unknown error'),
              onRetry: () =>
                  ref.read(searchFeedProvider(query).notifier).retryInitial(),
            );
          }
          if (feed.showInitialSpinner) {
            return _SearchStatus(title: searchText(context, 'searchLoading'));
          }
          if (feed.isEmptyAndReady) {
            return _SearchStatus(title: searchText(context, 'searchNoResults'));
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
          slivers: [
            if (entities.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _SearchStatus(
                  title: searchText(context, 'searchNoResults'),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(10),
                sliver: SliverMasonryGrid.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 5,
                  crossAxisSpacing: 10,
                  itemBuilder: (context, index) => IllustCard(
                    entity: entities[index],
                    heroScope: 'search:${query.cacheKey}',
                  ),
                  childCount: entities.length,
                ),
              ),
            SliverToBoxAdapter(
              child: _SearchFeedTail(
                feed: feed,
                onRetry: () => ref
                    .read(searchFeedProvider(query).notifier)
                    .retryLoadMore(),
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
          itemCount: entities.isEmpty ? 1 : entities.length + 1,
          itemBuilder: (context, index) {
            if (entities.isEmpty) {
              return SizedBox(
                height: 260,
                child: _SearchStatus(
                  title: searchText(context, 'searchNoResults'),
                ),
              );
            }
            if (index == entities.length) {
              return _SearchFeedTail(
                feed: feed,
                onRetry: () => ref
                    .read(searchFeedProvider(query).notifier)
                    .retryLoadMore(),
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
          itemCount: users.isEmpty ? 1 : users.length + 1,
          itemBuilder: (context, index) {
            if (users.isEmpty) {
              return SizedBox(
                height: 260,
                child: _SearchStatus(
                  title: searchText(context, 'searchNoResults'),
                ),
              );
            }
            if (index == users.length) {
              return _SearchFeedTail(
                feed: feed,
                onRetry: () => ref
                    .read(searchFeedProvider(query).notifier)
                    .retryLoadMore(),
              );
            }
            return _SearchUserCard(user: users[index]);
          },
        ),
      ),
    );
  }
}

class _SearchUserCard extends StatelessWidget {
  const _SearchUserCard({required this.user});

  final UserEntity user;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        onTap: () => showUserPage(context, user.id),
        leading: CircleAvatar(
          radius: 26,
          child: user.profileImageUrl == null
              ? const Icon(Icons.person_outline)
              : ClipOval(
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: PixivImage(
                      url: user.profileImageUrl!,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
        ),
        title: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: user.account.isEmpty
            ? null
            : Text(
                '${searchText(context, 'searchUserAccount')}: ${user.account}',
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

class _SearchStatus extends StatelessWidget {
  const _SearchStatus({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search, size: 44),
          const SizedBox(height: 12),
          Text(title),
        ],
      ),
    );
  }
}

class _SearchResultError extends StatelessWidget {
  const _SearchResultError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(searchText(context, 'searchLoadFailed')),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: Text(searchText(context, 'searchRetry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchFeedTail extends StatelessWidget {
  const _SearchFeedTail({required this.feed, required this.onRetry});

  final PagedFeedState feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (feed.showLoadMoreSpinner) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (feed.showLoadMoreError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(searchText(context, 'searchLoadMoreFailed')),
              Text(
                '${feed.loadMoreError}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton(
                onPressed: onRetry,
                child: Text(searchText(context, 'searchRetry')),
              ),
            ],
          ),
        ),
      );
    }
    if (feed.refreshPhase == FeedPhase.error) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          searchText(context, 'searchRefreshFailed'),
          textAlign: TextAlign.center,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
