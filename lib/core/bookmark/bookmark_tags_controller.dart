import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'bookmark_models.dart';
import 'bookmark_repository.dart';

/// Query identity for the user's bookmark tag list: entity type + visibility.
typedef BookmarkTagQuery = (BookmarkEntityType, BookmarkRestrict);

@immutable
class UserBookmarkTagsState {
  const UserBookmarkTagsState({
    required this.tags,
    this.nextUrl,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<UserBookmarkTag> tags;
  final String? nextUrl;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get hasMore => nextUrl != null;

  UserBookmarkTagsState copyWith({
    List<UserBookmarkTag>? tags,
    String? nextUrl,
    bool? loadingMore,
    Object? loadMoreError,
    bool clearNextUrl = false,
    bool clearLoadMoreError = false,
  }) {
    return UserBookmarkTagsState(
      tags: tags ?? this.tags,
      nextUrl: clearNextUrl ? null : (nextUrl ?? this.nextUrl),
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

/// Paged list of the signed-in user's bookmark tags. Not a PagedFeedController:
/// the payload is tag names, not entity ids, and there is no shared tag store.
class _UserBookmarkTagsController extends AsyncNotifier<UserBookmarkTagsState> {
  _UserBookmarkTagsController(this.query);

  final BookmarkTagQuery query;

  @override
  Future<UserBookmarkTagsState> build() async {
    // Account switches re-resolve the whole list; tag collections are
    // account-scoped data.
    final userId = await ref.watch(
      accountStoreProvider.selectAsync((state) => state.usableCurrent?.userId),
    );
    if (userId == null) {
      return const UserBookmarkTagsState(tags: []);
    }
    return _fetch(userId, null);
  }

  Future<void> loadMore() async {
    final current = state.value;
    final nextUrl = current?.nextUrl;
    if (current == null || nextUrl == null || current.loadingMore) return;
    final userId = ref.read(accountStoreProvider).value?.usableCurrent?.userId;
    if (userId == null) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _fetch(userId, nextUrl);
      state = AsyncData(
        current.copyWith(
          tags: [...current.tags, ...page.tags],
          nextUrl: page.nextUrl,
          loadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } on Object catch (error) {
      state = AsyncData(
        current.copyWith(loadingMore: false, loadMoreError: error),
      );
    }
  }

  Future<void> refresh() async {
    final userId = ref.read(accountStoreProvider).value?.usableCurrent?.userId;
    if (userId == null) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _fetch(userId, null));
  }

  Future<UserBookmarkTagsState> _fetch(int userId, String? cursor) {
    return ref
        .read(bookmarkRepositoryProvider)
        .fetchUserTags(
          userId,
          entityType: query.$1,
          restrict: query.$2,
          cursor: cursor,
        )
        .then(
          (page) =>
              UserBookmarkTagsState(tags: page.tags, nextUrl: page.nextUrl),
        );
  }
}

final userBookmarkTagsProvider =
    AsyncNotifierProvider.family<
      _UserBookmarkTagsController,
      UserBookmarkTagsState,
      BookmarkTagQuery
    >(_UserBookmarkTagsController.new);
