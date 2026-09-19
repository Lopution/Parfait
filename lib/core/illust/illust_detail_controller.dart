/// Snapshot-first illustration detail state and its repository boundary.
/// The controller owns detail request state; [IllustStore] owns the merged
/// entity. See `frontend/state-management.md`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../entity/illust_entity.dart';
import '../entity/illust_store.dart';
import '../network/api_error.dart';
import '../network/compat/network_providers.dart';
import '../network/pixiv_http_client.dart';
import '../profile/web_profile_session.dart';
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

class _IllustDetailController extends AsyncNotifier<IllustDetailState> {
  _IllustDetailController(this.illustId);

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
      final repository = ref.read(_illustDetailRepositoryProvider);
      // When the snapshot already proves the work is multi-page (the
      // feed→detail path), the pages call races the app detail instead of
      // queueing behind it — Shaft's fetchIllustPageDimensions pattern.
      final dimsFuture = (snapshot?.pageCount ?? 0) > 1
          ? repository.fetchPageDimensions(id)
          : null;
      final fresh = await repository.fetch(id);
      store.mergeAll(
        [fresh],
        source: EntityMergeSource.detail,
        bookmarkSnapshotRevision: bookmarkRevision,
      );
      final merged = store.get(id)!;
      if (!merged.visible) {
        return IllustDetailRestricted(merged);
      }
      if (merged.pageCount > 1 && merged.metaPages.isNotEmpty) {
        // Never block Ready on the dims: the slots re-layout to true ratios
        // whenever the web call lands, like Shaft's seedPageDimensions.
        unawaited(
          _seedPageDimensions(
            id,
            dimsFuture ?? repository.fetchPageDimensions(id),
          ),
        );
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

  /// Enriches the merged entity with true per-page dimensions once the web
  /// call lands and re-emits Ready so placeholders re-layout — the detail
  /// surface is never held for the extra round trip.
  Future<void> _seedPageDimensions(
    int id,
    Future<List<({int width, int height})>?> dimsFuture,
  ) async {
    try {
      final dims = await dimsFuture;
      if (dims == null) return;
      final store = ref.read(illustStoreProvider);
      final current = store.get(id);
      if (current == null) return;
      final enriched = current.withPageDimensions(dims);
      if (identical(enriched, current)) return;
      store.mergeAll([enriched], source: EntityMergeSource.detail);
      if (state.asData?.value is IllustDetailReady) {
        state = AsyncData(IllustDetailReady(store.get(id)!));
      }
    } on StateError {
      // The controller was disposed while the web call was in flight.
    }
  }
}

/// Optional web-transport override for `fetchPageDimensions` — tests inject
/// a MockClient so the `/ajax/illust/{id}/pages` call never reaches the
/// network. `null` (default) builds the shared pixivWeb policy client.
final illustDetailWebClientProvider = Provider<http.Client?>((ref) => null);

final _illustDetailRepositoryProvider = Provider<IllustDetailRepository>(
  (ref) => IllustDetailRepository(
    ref.watch(pixivHttpClientProvider),
    session: const MethodChannelWebProfileSession(),
    policy: ref.watch(networkAccessPolicyProvider),
    webClient: ref.watch(illustDetailWebClientProvider),
  ),
);

final illustDetailControllerProvider =
    AsyncNotifierProvider.family<
      _IllustDetailController,
      IllustDetailState,
      int
    >(_IllustDetailController.new);
