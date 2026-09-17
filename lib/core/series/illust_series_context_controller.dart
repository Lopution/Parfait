import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_store.dart';
import 'series_models.dart';
import 'series_repository.dart';
import 'series_store.dart';

/// Loads `/v1/illust-series/illust` for the detail-page series section.
///
/// This is a single fetch, not a paged feed, so there is no commit gate —
/// the notifier is the valid write path. The series detail merges into the
/// IllustSeriesStore and the prev/next neighbour payloads into the shared
/// IllustStore (gated on the fetch-time bookmark revision) so the section's
/// navigation buttons can push a detail page with a warm entity.
class _IllustSeriesContextController
    extends AsyncNotifier<IllustSeriesContext?> {
  _IllustSeriesContextController(this.illustId);

  final int illustId;

  @override
  Future<IllustSeriesContext?> build() async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final illustStore = ref.read(illustStoreProvider);
    final bookmarkRevision = illustStore.bookmarkRevisionNow();
    final result = await ref
        .read(seriesRepositoryProvider)
        .fetchIllustSeriesContext(illustId);
    final detail = result.detail;
    if (detail != null) {
      ref.read(illustSeriesStoreProvider.notifier).mergeAll([detail]);
    }
    final neighbours = [
      if (result.prevIllust != null) result.prevIllust!,
      if (result.nextIllust != null) result.nextIllust!,
    ];
    if (neighbours.isNotEmpty) {
      illustStore.mergeAll(
        neighbours,
        bookmarkSnapshotRevision: bookmarkRevision,
      );
    }
    return result.context;
  }
}

final illustSeriesContextProvider =
    AsyncNotifierProvider.family<
      _IllustSeriesContextController,
      IllustSeriesContext?,
      int
    >(_IllustSeriesContextController.new);
