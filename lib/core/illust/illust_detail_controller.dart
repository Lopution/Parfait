/// Snapshot-first illustration detail state and its repository boundary.
/// The controller owns detail request state; [IllustStore] owns the merged
/// entity. See `frontend/state-management.md`.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../entity/illust_entity.dart';
import '../entity/illust_store.dart';
import '../log.dart';
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

/// How long a list payload stands in for the detail one. Past it the counts
/// are worth refreshing — in the background, behind the snapshot.
const illustDetailFreshness = Duration(minutes: 10);

class _IllustDetailController extends AsyncNotifier<IllustDetailState> {
  _IllustDetailController(this.illustId);

  final int illustId;

  @override
  Future<IllustDetailState> build() => _load(illustId);

  /// Shaft's rule: a snapshot that carries every page URL draws the whole
  /// page, so it is Ready at once and costs no request — swiping through
  /// a feed's works sends no detail call for them. Only a stale snapshot,
  /// or an empty caption no detail payload has confirmed (some list
  /// endpoints trim captions), refetches, in the background.
  Future<IllustDetailState> _load(int id) async {
    // This build's ref: a rebuild (account switch) unmounts it, so work
    // started here never writes into the next build's state.
    final buildRef = ref;
    final store = ref.watch(illustStoreProvider);
    final snapshot = store.get(id);
    if (snapshot != null && !snapshot.visible) {
      return IllustDetailRestricted(snapshot);
    }
    if (snapshot == null || !snapshot.hasEveryPageUrl) {
      return _fetch(id, snapshot);
    }
    if (_wantsDetail(store, snapshot)) {
      // After build's Ready has landed: the refresh replaces it.
      unawaited(Future(() => _refreshInBackground(buildRef)));
    }
    if (snapshot.pageCount > 1 && !snapshot.hasPageDimensions) {
      unawaited(
        _seedPageDimensions(
          id,
          ref.read(_illustDetailRepositoryProvider).fetchPageDimensions(id),
          buildRef,
        ),
      );
    }
    return IllustDetailReady(snapshot);
  }

  static bool _wantsDetail(IllustStore store, IllustEntity snapshot) {
    if (snapshot.caption.isEmpty && !store.hasDetail(snapshot.id)) return true;
    final receivedAt = store.receivedAt(snapshot.id);
    return receivedAt == null ||
        clock.now().difference(receivedAt) > illustDetailFreshness;
  }

  Future<void> _refreshInBackground(Ref buildRef) async {
    if (!buildRef.mounted) return;
    final store = ref.read(illustStoreProvider);
    final result = await _fetch(illustId, store.get(illustId));
    if (!buildRef.mounted) return;
    if (result is IllustDetailError) {
      // The snapshot on screen stays; the next visit tries again.
      log(
        'illust $illustId: background detail refresh failed: ${result.error}',
      );
      return;
    }
    state = AsyncData(result);
  }

  Future<IllustDetailState> _fetch(int id, IllustEntity? snapshot) async {
    final buildRef = ref;
    final store = ref.read(illustStoreProvider);
    try {
      // Snapshot revision captured before the fetch gates stale bookmark
      // payloads against locally confirmed changes (R2).
      final bookmarkRevision = store.bookmarkRevisionNow();
      final repository = ref.read(_illustDetailRepositoryProvider);
      // When the snapshot already proves the work is multi-page (the
      // feed→detail path), the pages call races the app detail instead of
      // queueing behind it.
      final wantsDims =
          (snapshot?.pageCount ?? 0) > 1 && !snapshot!.hasPageDimensions;
      final dimsFuture = wantsDims ? repository.fetchPageDimensions(id) : null;
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
      if (merged.pageCount > 1 &&
          merged.metaPages.isNotEmpty &&
          !merged.hasPageDimensions) {
        // Never block Ready on the dims: the slots re-layout to true ratios
        // whenever the web call lands.
        unawaited(
          _seedPageDimensions(
            id,
            dimsFuture ?? repository.fetchPageDimensions(id),
            buildRef,
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

  /// Re-runs the fetch (pull-to-refresh / error retry): always asks the
  /// server, however fresh the snapshot.
  Future<void> reload() async {
    state = const AsyncLoading<IllustDetailState>();
    state = await AsyncValue.guard(
      () => _fetch(illustId, ref.read(illustStoreProvider).get(illustId)),
    );
  }

  /// Enriches the merged entity with true per-page dimensions once the web
  /// call lands and re-emits Ready so placeholders re-layout — the detail
  /// surface is never held for the extra round trip.
  Future<void> _seedPageDimensions(
    int id,
    Future<List<({int width, int height})>?> dimsFuture,
    Ref buildRef,
  ) async {
    final dims = await dimsFuture;
    if (dims == null || !buildRef.mounted) return;
    final store = ref.read(illustStoreProvider);
    if (!store.applyPageDimensions(id, dims)) return;
    if (state.asData?.value is IllustDetailReady) {
      state = AsyncData(IllustDetailReady(store.get(id)!));
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
