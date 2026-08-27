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
      final IllustSearchQuery value => _fetchIllust(
        repository,
        value,
        cursor,
        cancelToken,
      ),
      final NovelSearchQuery value => _fetchNovel(
        repository,
        value,
        cursor,
        cancelToken,
      ),
      final UserSearchQuery value => _fetchUsers(
        repository,
        value,
        cursor,
        cancelToken,
      ),
    };
  }

  Future<({List<int> ids, String? nextCursor})> _fetchIllust(
    SearchRepository repository,
    IllustSearchQuery query,
    String? cursor,
    CancelToken cancelToken,
  ) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await repository.searchIllust(
      query,
      cursor: cursor,
      cancelToken: cancelToken,
    );
    store.mergeAll(page.illusts, bookmarkSnapshotRevision: bookmarkRevision);
    return (
      ids: [for (final item in page.illusts) item.id],
      nextCursor: page.nextUrl,
    );
  }

  Future<({List<int> ids, String? nextCursor})> _fetchNovel(
    SearchRepository repository,
    NovelSearchQuery query,
    String? cursor,
    CancelToken cancelToken,
  ) async {
    final page = await repository.searchNovel(
      query,
      cursor: cursor,
      cancelToken: cancelToken,
    );
    ref.read(novelStoreProvider.notifier).mergeAll(page.novels);
    return (
      ids: [for (final item in page.novels) item.id],
      nextCursor: page.nextUrl,
    );
  }

  Future<({List<int> ids, String? nextCursor})> _fetchUsers(
    SearchRepository repository,
    UserSearchQuery query,
    String? cursor,
    CancelToken cancelToken,
  ) async {
    final store = ref.read(userStoreProvider.notifier);
    final followRevision = store.followRevisionNow();
    final page = await repository.searchUsers(
      query,
      cursor: cursor,
      cancelToken: cancelToken,
    );
    store.mergeAll(page.users, followSnapshotRevision: followRevision);
    return (
      ids: [for (final item in page.users) item.id],
      nextCursor: page.nextUrl,
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
