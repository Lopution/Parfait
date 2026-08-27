import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_store.dart';
import '../network/pixiv_http_client.dart';
import '../novel/novel_store.dart';
import '../paging/paged_feed_controller.dart';
import 'new_feed_models.dart';
import 'new_feed_repository.dart';

/// One independently lazy-paged New scope/type combination.
class NewFeedController extends PagedFeedController {
  NewFeedController(this.key);

  final NewFeedKey key;

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor) {
    return fetchPageCancellable(cursor, CancelToken());
  }

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPageCancellable(
    String? cursor,
    CancelToken cancelToken,
  ) async {
    // This dependency is deliberately inside each family member: all six
    // combinations reset at an account boundary without sharing cursors.
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final repository = ref.read(newFeedRepositoryProvider);
    if (key.type == NewFeedType.illust) {
      final store = ref.read(illustStoreProvider);
      final bookmarkRevision = store.bookmarkRevisionNow();
      final page = await repository.fetchIllust(
        key,
        cursor: cursor,
        cancelToken: cancelToken,
      );
      store.mergeAll(page.illusts, bookmarkSnapshotRevision: bookmarkRevision);
      return (
        ids: [for (final item in page.illusts) item.id],
        nextCursor: page.nextUrl,
      );
    }
    final page = await repository.fetchNovel(
      key,
      cursor: cursor,
      cancelToken: cancelToken,
    );
    ref.read(novelStoreProvider.notifier).mergeAll(page.novels);
    return (
      ids: [for (final item in page.novels) item.id],
      nextCursor: page.nextUrl,
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    final repository = ref.read(newFeedRepositoryProvider);
    final valid = key.type == NewFeedType.illust
        ? repository.validateIllustCursor(key, cursor: rawCursor)
        : repository.validateNovelCursor(key, cursor: rawCursor);
    return valid ? rawCursor : null;
  }
}

final newFeedProvider =
    AsyncNotifierProvider.family<NewFeedController, PagedFeedState, NewFeedKey>(
      NewFeedController.new,
    );
