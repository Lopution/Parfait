import 'dart:async';

import 'package:parfait/core/actionqueue/action_models.dart';
import 'package:parfait/core/actionqueue/action_store.dart';

/// The in-memory action store behind a database that misbehaves: with
/// [busyOnce] its first recovery fails, as a locked database did in the
/// field; while [claimGate] is set, a claim waits for it, holding a replay
/// between its row and its request.
final class FaultyActionStore implements ActionStore {
  FaultyActionStore(this._inner, {bool busyOnce = false}) : _busy = busyOnce;

  final InMemoryActionStore _inner;
  bool _busy;
  Completer<void>? claimGate;

  @override
  Future<({int reset, int dropped})> recoverInterrupted() async {
    if (!_busy) return _inner.recoverInterrupted();
    _busy = false;
    throw StateError('database is locked');
  }

  @override
  Future<bool> markRunning(int id) async {
    await claimGate?.future;
    return _inner.markRunning(id);
  }

  @override
  Future<int> enqueue(StoredAction draft) => _inner.enqueue(draft);
  @override
  Future<StoredAction?> nextReady(String owner, int nowMs) =>
      _inner.nextReady(owner, nowMs);
  @override
  Future<void> markPending(int id, {int? attempt, int? nextAttemptAtMs}) =>
      _inner.markPending(
        id,
        attempt: attempt,
        nextAttemptAtMs: nextAttemptAtMs,
      );
  @override
  Future<void> markFailed(int id) => _inner.markFailed(id);
  @override
  Future<void> delete(int id) => _inner.delete(id);
  @override
  Future<bool> deletePending(String owner, String dedupeKey) =>
      _inner.deletePending(owner, dedupeKey);
  @override
  Future<int?> nextPendingAt(String owner) => _inner.nextPendingAt(owner);
  @override
  Future<List<StoredAction>> listFor(String owner) => _inner.listFor(owner);
  @override
  Future<void> clearAccount(String owner) => _inner.clearAccount(owner);
}
