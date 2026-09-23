/// Session-only record of the most recently opened work inside each illust
/// series — feeds the series page's 「返回第 n 话」 affordance.
///
/// Deliberately in-memory only: the entry is a navigation aid for the
/// current session, not a reading-progress contract. Persistent progress
/// (a real schema) is explicitly out of scope for W4.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the series page needs to offer「返回第 n 话」: which work, and its
/// 1-based `content_order` label when the context probe carried it.
typedef SeriesRecentOpenEntry = ({int illustId, int? contentOrder});

/// Keyed `'$accountId:manga:$seriesId'` so parallel accounts never bleed
/// into each other's recents (the same shape the history providers use for
/// account scoping).
class SeriesRecentOpenStore
    extends Notifier<Map<String, SeriesRecentOpenEntry>> {
  @override
  Map<String, SeriesRecentOpenEntry> build() => const {};

  static String keyFor(String accountId, int seriesId) =>
      '$accountId:manga:$seriesId';

  SeriesRecentOpenEntry? read({
    required String accountId,
    required int seriesId,
  }) => state[keyFor(accountId, seriesId)];

  /// Records that [illustId] was opened inside [seriesId]. Re-recording the
  /// same entry is a no-op (no state churn on rebuilds).
  void record({
    required String accountId,
    required int seriesId,
    required int illustId,
    int? contentOrder,
  }) {
    final key = keyFor(accountId, seriesId);
    final existing = state[key];
    if (existing != null &&
        existing.illustId == illustId &&
        existing.contentOrder == contentOrder) {
      return;
    }
    state = {
      ...state,
      key: (illustId: illustId, contentOrder: contentOrder),
    };
  }
}

final seriesRecentOpenStoreProvider =
    NotifierProvider<SeriesRecentOpenStore, Map<String, SeriesRecentOpenEntry>>(
      SeriesRecentOpenStore.new,
    );
