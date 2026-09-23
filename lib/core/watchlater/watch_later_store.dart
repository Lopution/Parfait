import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_entity.dart';
import 'watch_later_database.dart';
import 'watch_later_repository.dart';

final watchLaterDatabaseProvider = Provider<WatchLaterDatabase>((ref) {
  final database = WatchLaterDatabase();
  ref.onDispose(database.close);
  return database;
});

final watchLaterRepositoryProvider = Provider<WatchLaterRepository>((ref) {
  return WatchLaterRepository(database: ref.watch(watchLaterDatabaseProvider));
});

/// Account-scoped watch-later list, newest first. Pure-local: the store
/// talks to SQLite only, so the feature works without connectivity and an
/// account switch just rebuilds with the new account's rows.
class WatchLaterStore extends AsyncNotifier<List<WatchLaterEntry>> {
  @override
  Future<List<WatchLaterEntry>> build() {
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    if (accountId == null) return Future.value(const <WatchLaterEntry>[]);
    return ref.read(watchLaterRepositoryProvider).list(accountId);
  }

  String? get _accountId =>
      ref.read(accountStoreProvider).value?.usableCurrent?.id;

  /// Idempotent: re-adding refreshes the timestamp. Returns false when no
  /// account is logged in (nothing to key the row to).
  Future<bool> add(IllustEntity entity) async {
    final accountId = _accountId;
    if (accountId == null) return false;
    final repository = ref.read(watchLaterRepositoryProvider);
    await repository.add(accountId, entity);
    ref.invalidateSelf();
    return true;
  }

  /// Undo for the remove flow: re-inserts [entry] with its original
  /// `addedAt` so the row lands back at its old position instead of
  /// jumping to the front like a fresh [add] would. Returns false when no
  /// account is logged in.
  Future<bool> restore(WatchLaterEntry entry) async {
    final accountId = _accountId;
    if (accountId == null) return false;
    await ref
        .read(watchLaterRepositoryProvider)
        .add(accountId, entry.entity, addedAt: entry.addedAt);
    ref.invalidateSelf();
    return true;
  }

  Future<void> remove(int illustId) async {
    final accountId = _accountId;
    if (accountId == null) return;
    await ref.read(watchLaterRepositoryProvider).remove(accountId, illustId);
    ref.invalidateSelf();
  }

  Future<void> clear() async {
    final accountId = _accountId;
    if (accountId == null) return;
    await ref.read(watchLaterRepositoryProvider).clear(accountId);
    ref.invalidateSelf();
  }

  bool contains(int illustId) {
    return (state.value ?? const <WatchLaterEntry>[]).any(
      (entry) => entry.entity.id == illustId,
    );
  }
}

final watchLaterStoreProvider =
    AsyncNotifierProvider<WatchLaterStore, List<WatchLaterEntry>>(
      WatchLaterStore.new,
    );
