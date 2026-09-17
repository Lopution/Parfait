import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_store.dart';
import '../paging/paged_feed_controller.dart';
import 'series_repository.dart';
import 'series_store.dart';

/// Paginated works of one illust series (`/v1/illust/series`, newest first).
///
/// The feed owns only ordered IDs; illust payloads commit into the shared
/// IllustStore and the series detail into the canonical IllustSeriesStore,
/// both inside the commit gate so a stale/cancelled page writes nothing.
class _IllustSeriesFeedController extends PagedFeedController {
  _IllustSeriesFeedController(this.seriesId);

  final int seriesId;

  @override
  String get feedKey => 'series:works:$seriesId';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final repository = ref.read(seriesRepositoryProvider);
    final illustStore = ref.read(illustStoreProvider);
    final bookmarkRevision = illustStore.bookmarkRevisionNow();
    final page = await repository.fetchSeriesWorks(
      seriesId,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final illust in page.illusts) illust.id],
      nextCursor: page.nextUrl,
      incomingIllusts: {for (final illust in page.illusts) illust.id: illust},
      commit: (_) {
        illustStore.mergeAll(
          page.illusts,
          bookmarkSnapshotRevision: bookmarkRevision,
        );
        final detail = page.detail;
        if (detail != null) {
          ref.read(illustSeriesStoreProvider.notifier).mergeAll([detail]);
        }
      },
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(seriesRepositoryProvider)
            .validateSeriesCursor(seriesId, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

/// Paginated illust-series list of one user (`/v1/user/illust-series`,
/// offset cursor). Entries commit into the shared IllustSeriesStore.
class _UserSeriesFeedController extends PagedFeedController {
  _UserSeriesFeedController(this.userId);

  final int userId;

  @override
  String get feedKey => 'series:user:$userId';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final page = await ref
        .read(seriesRepositoryProvider)
        .fetchUserSeries(
          userId,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    return FeedPage(
      ids: [for (final series in page.series) series.id],
      nextCursor: page.nextUrl,
      commit: (_) =>
          ref.read(illustSeriesStoreProvider.notifier).mergeAll(page.series),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(seriesRepositoryProvider)
            .validateUserSeriesCursor(userId, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final illustSeriesFeedProvider =
    AsyncNotifierProvider.family<
      _IllustSeriesFeedController,
      PagedFeedState,
      int
    >(_IllustSeriesFeedController.new);

final userSeriesFeedProvider =
    AsyncNotifierProvider.family<
      _UserSeriesFeedController,
      PagedFeedState,
      int
    >(_UserSeriesFeedController.new);
