import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/pixiv_http_client.dart';
import '../paging/paged_feed_controller.dart';
import 'novel_repository.dart';
import 'novel_store.dart';

/// User work feed for Novel previews. Only IDs live in feed state; cards and
/// the reader observe [novelStoreProvider].
class UserNovelFeedController extends PagedFeedController {
  UserNovelFeedController(this.userId);

  final int userId;

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor) {
    return fetchPageCancellable(cursor, CancelToken());
  }

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPageCancellable(
    String? cursor,
    CancelToken cancelToken,
  ) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchUserNovels(userId, cursor: cursor, cancelToken: cancelToken);
    ref.read(novelStoreProvider.notifier).mergeAll(page.novels);
    return (
      ids: [for (final novel in page.novels) novel.id],
      nextCursor: page.nextUrl,
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

final userNovelFeedProvider =
    AsyncNotifierProvider.family<UserNovelFeedController, PagedFeedState, int>(
      UserNovelFeedController.new,
    );
