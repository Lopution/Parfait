import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../paging/paged_feed_controller.dart';
import 'novel_snapshot_codec.dart';
import 'novel_repository.dart';
import 'novel_store.dart';

/// One independent cursor/state machine per novel ranking mode.
class _NovelRankingFeedController extends PagedFeedController {
  _NovelRankingFeedController(this.mode);

  final NovelRankingMode mode;

  @override
  String get feedKey => 'novel-ranking:${mode.apiValue}';

  @override
  FeedSnapshotCodec? get snapshotCodec => const NovelSnapshotCodec();

  /// C9: ranking is discovery content.
  @override
  bool get localFilterEnabled => true;

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<PagedFeedState> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return super.build();
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final store = ref.read(novelStoreProvider.notifier);
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchRanking(
          mode,
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
    if (rawCursor == null || rawCursor.isEmpty) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateRankingCursor(mode, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final novelRankingFeedProvider =
    AsyncNotifierProvider.family<
      _NovelRankingFeedController,
      PagedFeedState,
      NovelRankingMode
    >(_NovelRankingFeedController.new);
