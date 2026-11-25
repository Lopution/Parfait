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
  _HistoryFeedController(this.query);

  /// Local history storage; resolved lazily through the provider graph.
  HistoryRepository get repository => ref.read(historyRepositoryProvider);

  final HistoryFeedQuery query;

  static const pageSize = 30;

  final Map<int, HistoryRecord> _records = {};

  @override
  String get feedKey =>
      'history:${query.accountId}:'
      '${query.contentType?.storageValue ?? 'all'}:'
      '${Uri.encodeComponent(query.query)}';

  @override
  FeedPagingPolicy get pagingPolicy => FeedPagingPolicy.unlimited;

  /// Stable state id for a record: content type in the high bits, so an
  /// illust and a novel may share a numeric id without colliding.
  static int keyOf(HistoryRecord record) =>
      (record.contentType.index << 32) | record.contentId;

  HistoryRecord? recordFor(int key) => _records[key];

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    try {
      // The cursor is the last row read: deleting a loaded row or viewing
      // a work again never shifts the next page (an offset skipped rows).
      final result = await repository.page(
        accountId: query.accountId,
        contentType: query.contentType,
        query: query.query.isEmpty ? null : query.query,
        after: _rowAfter(context.cursor),
        limit: pageSize,
      );
      for (final record in result.records) {
        _records[keyOf(record)] = record;
      }
      final last = result.records.lastOrNull;
      return FeedPage(
        ids: [for (final record in result.records) keyOf(record)],
        nextCursor: result.hasMore && last != null
            ? '${last.lastViewedAt.microsecondsSinceEpoch}:${last.rowId}'
            : null,
      );
    } on Object catch (error) {
      // History storage failures are local, not server API errors; wrap so
      // the base three-phase semantics can surface them.
      throw ApiParseError(error);
    }
  }

  static ({DateTime viewedAt, int rowId})? _rowAfter(String? cursor) {
    if (cursor == null) return null;
    final [viewedAt, rowId] = cursor.split(':').map(int.parse).toList();
    return (
      viewedAt: DateTime.fromMicrosecondsSinceEpoch(viewedAt, isUtc: true),
      rowId: rowId,
    );
  }

  /// Deletes one record and drops it from the visible feed.
  Future<void> removeRecord(HistoryRecord record) => removeRecords([record]);

  /// Deletes [records] in one transaction and updates the visible feed once.
  Future<void> removeRecords(List<HistoryRecord> records) async {
    if (records.isEmpty) return;
    await repository.deleteAll(query.accountId, [
      for (final record in records)
        (contentType: record.contentType, contentId: record.contentId),
    ]);
    final removedKeys = <int>{};
    for (final record in records) {
      final key = keyOf(record);
      removedKeys.add(key);
      _records.remove(key);
    }
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        ids: current.ids.where((key) => !removedKeys.contains(key)).toList(),
      ),
    );
  }
}

/// Released with the history page: a page opened again reads the history
/// afresh rather than the list it read last time.
final historyFeedControllerProvider = AsyncNotifierProvider.autoDispose
    .family<_HistoryFeedController, PagedFeedState, HistoryFeedQuery>(
      _HistoryFeedController.new,
    );
