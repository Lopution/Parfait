import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/api_date.dart';
import '../paging/paged_feed_controller.dart';
import 'novel_snapshot_codec.dart';
import 'novel_repository.dart';
import 'novel_store.dart';

/// A novel ranking list: the mode and, for a past ranking, its date (null
/// is the latest).
typedef NovelRankingFeedKey = ({NovelRankingMode mode, DateTime? date});

/// One independent cursor/state machine per novel ranking mode and date.
class _NovelRankingFeedController extends PagedFeedController {
  _NovelRankingFeedController(NovelRankingFeedKey key)
    : mode = key.mode,
      date = key.date;

  final NovelRankingMode mode;
  final DateTime? date;

  @override
  String get feedKey => switch (date) {
    null => 'novel-ranking:${mode.apiValue}',
    final date => 'novel-ranking:${mode.apiValue}@${formatApiDate(date)}',
  };

  /// Only the latest ranking is a cold-start snapshot: a past date must
  /// never overwrite it.
  @override
  FeedSnapshotCodec? get snapshotCodec =>
      date == null ? const NovelSnapshotCodec() : null;

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
          date: date,
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
            .validateRankingCursor(mode, cursor: rawCursor, date: date)
        ? rawCursor
        : null;
  }
}

final novelRankingFeedProvider =
    AsyncNotifierProvider.family<
      _NovelRankingFeedController,
      PagedFeedState,
      NovelRankingFeedKey
    >(_NovelRankingFeedController.new);
