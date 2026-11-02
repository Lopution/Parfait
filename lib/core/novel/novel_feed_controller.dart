import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../paging/paged_feed_controller.dart';
import '../profile/profile_models.dart';
import 'novel_snapshot_codec.dart';
import 'novel_repository.dart';
import 'novel_store.dart';

/// User work feed for Novel previews. Only IDs live in feed state; cards and
/// the reader observe [novelStoreProvider].
class _UserNovelFeedController extends PagedFeedController {
  _UserNovelFeedController(this.userId);

  final int userId;

  @override
  String get feedKey => 'profile:novel:$userId';

  @override
  FeedSnapshotCodec? get snapshotCodec => const NovelSnapshotCodec();

  /// C9: an author's works are discovery content, as for illusts.
  @override
  bool get localFilterEnabled => true;

  @override
  bool get novelIds => true;

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchUserNovels(
          userId,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    final store = ref.read(novelStoreProvider.notifier);
    return FeedPage(
      ids: [for (final novel in page.novels) novel.id],
      nextCursor: page.nextUrl,
      incomingNovels: {for (final novel in page.novels) novel.id: novel},
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateUserNovelsCursor(userId, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final userNovelFeedProvider = AsyncNotifierProvider.autoDispose
    .family<_UserNovelFeedController, PagedFeedState, int>(
      _UserNovelFeedController.new,
    );

/// A user's novel bookmarks: [ProfileFeedKey.kind] bookmarks with the novel
/// work type, of its restrict and tag.
class _UserNovelBookmarksFeedController extends PagedFeedController {
  _UserNovelBookmarksFeedController(this.key);

  final ProfileFeedKey key;

  @override
  String get feedKey => 'profile:novel:$key';

  @override
  FeedSnapshotCodec? get snapshotCodec => const NovelSnapshotCodec();

  /// C9: bookmarks are the user's own collection, as for illusts.
  @override
  bool get localFilterEnabled => false;

  @override
  bool get novelIds => true;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchUserBookmarks(
          key.userId,
          restrict: key.restrict,
          tag: key.bookmarkTag,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    final store = ref.read(novelStoreProvider.notifier);
    return FeedPage(
      ids: [for (final novel in page.novels) novel.id],
      nextCursor: page.nextUrl,
      incomingNovels: {for (final novel in page.novels) novel.id: novel},
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateUserBookmarksCursor(
              key.userId,
              restrict: key.restrict,
              tag: key.bookmarkTag,
              cursor: rawCursor,
            )
        ? rawCursor
        : null;
  }
}

final userNovelBookmarksFeedProvider = AsyncNotifierProvider.autoDispose
    .family<_UserNovelBookmarksFeedController, PagedFeedState, ProfileFeedKey>(
      _UserNovelBookmarksFeedController.new,
    );
