import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/pixiv_http_client.dart';
import 'illust_detail_repository.dart';

/// Sealed detail state: snapshot-first (R1) with explicit terminal states.
sealed class IllustDetailState {
  const IllustDetailState();
}

/// Terminal success state.
class IllustDetailReady extends IllustDetailState {
  const IllustDetailReady(this.entity);

  final IllustEntity entity;
}

/// Deleted / restricted / muted work.
class IllustDetailRestricted extends IllustDetailState {
  const IllustDetailRestricted(this.entity);

  final IllustEntity entity;
}

/// Unknown ID or removed work (API 404).
class IllustDetailNotFound extends IllustDetailState {
  const IllustDetailNotFound();
}

/// Fetch failed; retryable.
class IllustDetailError extends IllustDetailState {
  const IllustDetailError(this.error, {this.snapshot});

  final ApiError error;
  final IllustEntity? snapshot;

  /// True when a store snapshot is still renderable behind the error.
  bool get hasSnapshot => snapshot != null;
}

class IllustDetailController extends AsyncNotifier<IllustDetailState> {
  IllustDetailController(this.illustId);

  final int illustId;

  @override
  Future<IllustDetailState> build() => _load(illustId);

  Future<IllustDetailState> _load(int id) async {
    final store = ref.watch(illustStoreProvider);
    final snapshot = store.get(id);
    // Snapshot-first (R1): stale data renders immediately while refreshing.
    if (snapshot != null && !snapshot.visible) {
      return IllustDetailRestricted(snapshot);
    }
    try {
      // Snapshot revision captured before the fetch gates stale bookmark
      // payloads against locally confirmed changes (R2).
      final bookmarkRevision = store.bookmarkRevisionNow();
      final fresh = await ref.read(illustDetailRepositoryProvider).fetch(id);
      store.mergeAll([fresh], bookmarkSnapshotRevision: bookmarkRevision);
      final merged = store.get(id)!;
      if (!merged.visible) {
        return IllustDetailRestricted(merged);
      }
      return IllustDetailReady(merged);
      // Note: while this future is in flight the page renders the store
      // snapshot directly (snapshot-first, R1); no separate refreshing
      // state is needed.
    } on ApiHttpError catch (error) {
      if (error.statusCode == 404 || error.statusCode == 400) {
        return const IllustDetailNotFound();
      }
      return IllustDetailError(error, snapshot: snapshot);
    } on ApiError catch (error) {
      return IllustDetailError(error, snapshot: snapshot);
    }
  }

  /// Re-runs the fetch (pull-to-refresh / error retry).
  Future<void> reload() async {
    state = const AsyncLoading<IllustDetailState>();
    state = await AsyncValue.guard(() => _load(illustId));
  }
}

final illustDetailRepositoryProvider = Provider<IllustDetailRepository>(
  (ref) => IllustDetailRepository(ref.watch(pixivHttpClientProvider)),
);

final illustDetailControllerProvider =
    AsyncNotifierProvider.family<
      IllustDetailController,
      IllustDetailState,
      int
    >(IllustDetailController.new);
