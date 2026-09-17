/// Canonical account-scoped illust-series entities shared by the series
/// page, the profile series tab and the detail-page context section.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'series_models.dart';

/// Account-scoped canonical illust-series map. Feeds keep ordered IDs and
/// the series page reads the same entity, matching the IllustStore/NovelStore
/// boundary (`frontend/state-management.md`).
class IllustSeriesStore extends Notifier<Map<int, IllustSeriesEntity>> {
  @override
  Map<int, IllustSeriesEntity> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return {};
  }

  IllustSeriesEntity? get(int id) => state[id];

  List<IllustSeriesEntity> getAll(Iterable<int> ids) => [
    for (final id in ids)
      if (state[id] != null) state[id]!,
  ];

  /// Sparse payloads (user-series entries lack watchlist/concluded fields)
  /// must not erase richer values already observed — see
  /// [IllustSeriesEntity.mergeOver].
  void mergeAll(Iterable<IllustSeriesEntity> incoming) {
    final next = Map<int, IllustSeriesEntity>.of(state);
    for (final entity in incoming) {
      final existing = next[entity.id];
      next[entity.id] = existing == null ? entity : entity.mergeOver(existing);
    }
    state = next;
  }

  void clear() => state = {};
}

final illustSeriesStoreProvider =
    NotifierProvider<IllustSeriesStore, Map<int, IllustSeriesEntity>>(
      IllustSeriesStore.new,
    );
