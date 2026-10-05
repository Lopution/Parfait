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

/// What [WatchLaterStore.removeAll] took off whose list.
typedef WatchLaterRemoval = ({String accountId, List<WatchLaterEntry> entries});

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

  /// Removes [illustIds] from the current account's list in one
  /// transaction. The result is what [restoreAll] needs to undo it; null
  /// when signed out or none of the ids is on the list.
  Future<WatchLaterRemoval?> removeAll(Iterable<int> illustIds) async {
    final accountId = _accountId;
    if (accountId == null) return null;
    final ids = illustIds.toSet();
    final entries = [
      for (final entry in state.value ?? const <WatchLaterEntry>[])
        if (ids.contains(entry.entity.id)) entry,
    ];
    if (entries.isEmpty) return null;
    await ref.read(watchLaterRepositoryProvider).removeAll(accountId, [
      for (final entry in entries) entry.entity.id,
    ]);
    ref.invalidateSelf();
    return (accountId: accountId, entries: entries);
  }

  /// Undo for [removeAll]: re-inserts the entries with their original
  /// `addedAt`, so they land back at their old positions. Returns false —
  /// and restores nothing — once another account (or none) is current:
  /// the entries belong to the account they were removed from.
  Future<bool> restoreAll(WatchLaterRemoval removal) async {
    if (_accountId != removal.accountId) return false;
    await ref
        .read(watchLaterRepositoryProvider)
        .restoreAll(removal.accountId, removal.entries);
    ref.invalidateSelf();
    return true;
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
