import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_store.dart';
import '../novel/novel_store.dart';
import '../paging/paged_feed_controller.dart';
import 'new_feed_models.dart';
import 'new_feed_repository.dart';

/// One independently lazy-paged New scope/type combination.
class NewFeedController extends PagedFeedController {
  NewFeedController(this.key);

  final NewFeedKey key;

  @override
  String get feedKey => 'new:${key.scope.name}:${key.type.name}';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final repository = ref.read(newFeedRepositoryProvider);
    if (key.type == NewFeedType.illust) {
      final store = ref.read(illustStoreProvider);
      final bookmarkRevision = store.bookmarkRevisionNow();
      final page = await repository.fetchIllust(
        key,
        cursor: context.cursor,
        cancelToken: context.cancelToken,
      );
      return FeedPage(
        ids: [for (final item in page.illusts) item.id],
        nextCursor: page.nextUrl,
        incomingIllusts: {for (final item in page.illusts) item.id: item},
        commit: (_) => store.mergeAll(
          page.illusts,
          bookmarkSnapshotRevision: bookmarkRevision,
        ),
      );
    }
    final store = ref.read(novelStoreProvider.notifier);
    final page = await repository.fetchNovel(
      key,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final item in page.novels) item.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(page.novels),
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
