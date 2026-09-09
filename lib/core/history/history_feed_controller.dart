import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_error.dart';
import '../paging/paged_feed_controller.dart';
import 'history_models.dart';
import 'history_repository.dart';

/// PagedFeedController over the local browsing history (C7b).
///
/// History rows are (contentType, contentId) pairs, not illust IDs, so the
/// controller keeps a plain side map from the encoded state key to the
/// [HistoryRecord]; `ids` only carry the encoded key. Account scoping comes
/// from the family argument and is re-asserted by the base controller's
/// account watch. The remote-sync outbox lives in the tracker layer and is
/// untouched by this UI feed.
class _HistoryFeedController extends PagedFeedController {
  _HistoryFeedController(this.accountId);

  /// Local history storage; resolved lazily through the provider graph.
  HistoryRepository get repository => ref.read(historyRepositoryProvider);

  final String accountId;

  static const pageSize = 30;

  final Map<int, HistoryRecord> _records = {};

  @override
  String get feedKey => 'history:$accountId';

  /// Stable state id for a record: content type in the high bits, so an
  /// illust and a novel may share a numeric id without colliding.
  static int keyOf(HistoryRecord record) =>
      (record.contentType.index << 32) | record.contentId;

  HistoryRecord? recordFor(int key) => _records[key];

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    try {
      final result = await repository.page(
        accountId: accountId,
        offset: context.page * pageSize,
        limit: pageSize,
      );
      for (final record in result.records) {
        _records[keyOf(record)] = record;
      }
      return FeedPage(
        ids: [for (final record in result.records) keyOf(record)],
        nextCursor: result.hasMore ? '${(context.page + 1) * pageSize}' : null,
      );
    } on Object catch (error) {
      // History storage failures are local, not server API errors; wrap so
      // the base three-phase semantics can surface them.
      throw ApiParseError(error);
    }
  }

  /// Deletes one record and drops it from the visible feed.
  Future<void> removeRecord(HistoryRecord record) async {
    await repository.delete(
      accountId: accountId,
      contentType: record.contentType,
      contentId: record.contentId,
    );
    _records.remove(keyOf(record));
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        ids: current.ids.where((key) => key != keyOf(record)).toList(),
      ),
    );
  }
}

final historyFeedControllerProvider =
    AsyncNotifierProvider.family<
      _HistoryFeedController,
      PagedFeedState,
      String
    >(_HistoryFeedController.new);
