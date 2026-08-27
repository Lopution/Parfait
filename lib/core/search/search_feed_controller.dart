import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_store.dart';
import '../network/pixiv_http_client.dart';
import '../novel/novel_store.dart';
import '../paging/paged_feed_controller.dart';
import '../user/user_store.dart';
import 'search_models.dart';
import 'search_repository.dart';

/// One independent result state for one typed query and account.
class SearchFeedController extends PagedFeedController {
  SearchFeedController(this.query);

  final SearchQuery query;

  @override
  String get feedKey => 'search:${query.cacheKey}';

  @override
  Future<PagedFeedState> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return super.build();
  }

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor) {
    return fetchPageCancellable(cursor, CancelToken());
  }

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPageCancellable(
    String? cursor,
    CancelToken cancelToken,
  ) async {
    final repository = ref.read(searchRepositoryProvider);
    return switch (query) {
      final IllustSearchQuery value => () async {
        final page = await repository.searchIllust(
          value,
          cursor: cursor,
          cancelToken: cancelToken,
        );
        return (
          ids: [for (final item in page.illusts) item.id],
          nextCursor: page.nextUrl,
        );
      }(),
      final NovelSearchQuery value => () async {
        final page = await repository.searchNovel(
          value,
          cursor: cursor,
          cancelToken: cancelToken,
        );
        return (
          ids: [for (final item in page.novels) item.id],
          nextCursor: page.nextUrl,
        );
      }(),
      final UserSearchQuery value => () async {
        final page = await repository.searchUsers(
          value,
          cursor: cursor,
          cancelToken: cancelToken,
        );
        return (
          ids: [for (final item in page.users) item.id],
          nextCursor: page.nextUrl,
        );
      }(),
    };
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) {
    final repository = ref.read(searchRepositoryProvider);
    return switch (query) {
      final IllustSearchQuery value => _fetchIllustForContext(
        repository,
        value,
        context,
      ),
      final NovelSearchQuery value => _fetchNovelForContext(
        repository,
        value,
        context,
      ),
      final UserSearchQuery value => _fetchUsersForContext(
        repository,
        value,
        context,
      ),
    };
  }

  Future<FeedPage> _fetchIllustForContext(
    SearchRepository repository,
    IllustSearchQuery query,
    FeedRequestContext context,
  ) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await repository.searchIllust(
      query,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final item in page.illusts) item.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(
        page.illusts,
        bookmarkSnapshotRevision: bookmarkRevision,
      ),
    );
  }

  Future<FeedPage> _fetchNovelForContext(
    SearchRepository repository,
    NovelSearchQuery query,
    FeedRequestContext context,
  ) async {
    final page = await repository.searchNovel(
      query,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    final store = ref.read(novelStoreProvider.notifier);
    return FeedPage(
      ids: [for (final item in page.novels) item.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  Future<FeedPage> _fetchUsersForContext(
    SearchRepository repository,
    UserSearchQuery query,
    FeedRequestContext context,
  ) async {
    final store = ref.read(userStoreProvider.notifier);
    final followRevision = store.followRevisionNow();
    final page = await repository.searchUsers(
      query,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final item in page.users) item.id],
      nextCursor: page.nextUrl,
      commit: (_) =>
          store.mergeAll(page.users, followSnapshotRevision: followRevision),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null || rawCursor.isEmpty) return null;
    return ref
            .read(searchRepositoryProvider)
            .validateCursor(query, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final searchFeedProvider =
    AsyncNotifierProvider.family<
      SearchFeedController,
      PagedFeedState,
      SearchQuery
    >(SearchFeedController.new);
