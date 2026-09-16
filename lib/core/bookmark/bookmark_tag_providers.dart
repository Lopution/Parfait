import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'bookmark_models.dart';
import 'bookmark_repository.dart';

/// Confirmed bookmark state for the edit sheet's prefill. Loaded on demand;
/// only meaningful while the work is bookmarked.
final bookmarkDetailProvider = FutureProvider.autoDispose
    .family<BookmarkDetail, BookmarkKey>((ref, key) {
      return ref.watch(bookmarkRepositoryProvider).fetchDetail(key);
    });

typedef BookmarkTagSuggestionQuery = (BookmarkEntityType, BookmarkRestrict);

/// First page of the user's own bookmark tag collection, used as suggestion
/// chips in the bookmark sheet. Suggestions need no full pagination — the
/// management page owns the complete paged list.
final userBookmarkTagSuggestionsProvider = FutureProvider.autoDispose
    .family<List<UserBookmarkTag>, BookmarkTagSuggestionQuery>((
      ref,
      query,
    ) async {
      final account = await ref.watch(accountStoreProvider.future);
      final userId = account.usableCurrent?.userId;
      if (userId == null) return const [];
      final page = await ref
          .watch(bookmarkRepositoryProvider)
          .fetchUserTags(userId, entityType: query.$1, restrict: query.$2);
      return page.tags;
    });
