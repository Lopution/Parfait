/// Persistent offline action queue. Mutations that fail on connectivity
/// are enqueued per account and replayed serially once the app is back
/// online.
///
/// Failure taxonomy:
/// - [RetryScope.queueCooldown] — network/timeout/429/5xx: the row returns
///   to pending untouched and the whole owner queue sleeps for a cooldown
///   (a 429 `retryAfter` hint overrides the default).
/// - [RetryScope.row] — 4xx/business/unknown rejections: only that row
///   backs off with a growing attempt counter; [maxAttempts] drops it.
///
/// Wake-ups: besides explicit drains (startup, account switch, resume,
/// network restore, a successful mutation) the queue re-arms itself with
/// one timer per owner — when the cooldown or the first row backoff ends,
/// and one cooldown after an enqueue, since every enqueue follows a
/// connectivity failure that no restore event may ever report.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../log.dart';
import '../network/api_error.dart';
import 'action_models.dart';
import 'action_store.dart';

/// Executes one queued action. Handlers call the same repository methods
/// the online mutation uses, so a replay converges through the identical
/// confirmation path. Throwing an [ApiError] (or anything) fails the row —
/// the engine classifies the error into a [RetryScope].
typedef ActionHandler = FutureOr<void> Function(StoredAction action);

final class ActionQueue {
  ActionQueue({
    required ActionStore store,
    DateTime Function()? now,
    this.maxAttempts = 5,
    this.cooldown = const Duration(seconds: 30),
    this.rowBackoff = const Duration(seconds: 10),
  }) : _store = store,
       _now = now ?? DateTime.now;

  /// Row retries allowed before the action is marked failed and counted in
  /// [ActionTelemetry.dropped].
  final int maxAttempts;

  /// Whole-queue sleep after a connectivity-class failure.
  final Duration cooldown;

  /// Per-attempt linear backoff for row-scope retries.
  final Duration rowBackoff;

  final ActionStore _store;
  final DateTime Function() _now;
  final Map<String, ActionHandler> _handlers = {};
  final Set<String> _draining = {};
  final Map<String, DateTime> _cooldownUntil = {};
  final Map<String, Timer> _wakes = {};
  final Set<String> _parked = {};
  Future<void>? _recovery;
  var _disposed = false;

  /// Cumulative counters since construction (replayed / dropped).
  final telemetry = ActionTelemetry();

  /// Registers the replay handler for one action type.
  void registerHandler(String type, ActionHandler handler) {
    _handlers[type] = handler;
  }

  /// Enqueues [payload] under `type`/`dedupeKey` for [owner]. A pending row
  /// with the same key is replaced — rapid toggles coalesce to the last
  /// intent. Returns the row id.
  Future<int> enqueue({
    required String owner,
    required String type,
    required String dedupeKey,
    required Map<String, Object?> payload,
  }) async {
    final draft = StoredAction(
      id: 0,
      owner: owner,
      type: type,
      dedupeKey: dedupeKey,
      payload: jsonEncode(payload),
      status: ActionStatus.pending,
      attempt: 0,
      createdAt: _now().millisecondsSinceEpoch,
    );
    final id = await _store.enqueue(draft);
    if (!_wakes.containsKey(owner)) _wakeAt(owner, _now().add(cooldown));
    return id;
  }

  /// Takes back [owner]'s queued intent under [dedupeKey]. False when no
  /// pending row is left to drop — never queued, replayed, or replaying.
  Future<bool> dropPending({
    required String owner,
    required String dedupeKey,
  }) => _store.deletePending(owner, dedupeKey);

  /// Drains [owner]'s ready rows serially, oldest first, then arms the
  /// owner's wake for whatever is left. Re-entrant calls are coalesced — a
  /// drain already in progress simply continues. A queue-cooldown failure
  /// stops the drain until [cooldown] elapses. The first drain of a queue
  /// recovers rows a killed process left running (the queue is built once
  /// per process). Drains a [park]ed owner again.
  Future<void> drain(String owner) async {
    if (_disposed) return;
    _parked.remove(owner);
    try {
      await _recoverFor(owner);
      await _drainExclusive(owner);
    } on Object {
      // The store closes together with the queue: a drain that dispose
      // caught mid-flight has nothing left to report.
      if (!_disposed) rethrow;
    }
  }

  /// Clears [owner]'s cooldown and drains now: the device just regained a
  /// network, so the failure the cooldown waits out is likely over. Row
  /// backoffs stay — they follow rejections, not lost connectivity.
  Future<void> retryNow(String owner) {
    _cooldownUntil.remove(owner);
    return drain(owner);
  }

  /// Stops waking [owner] after an account switch or sign-out: cancels its
  /// wake and ends a running drain after the current row, so no row of
  /// [owner] replays under another account's credentials.
  void park(String owner) {
    _parked.add(owner);
    _wakes.remove(owner)?.cancel();
  }

  /// Cancels every wake; nothing drains or re-arms afterwards.
  void dispose() {
    _disposed = true;
    for (final wake in _wakes.values) {
      wake.cancel();
    }
    _wakes.clear();
  }

  Future<void> _drainExclusive(String owner) async {
    if (!_draining.add(owner)) return;
    _wakes.remove(owner)?.cancel();
    try {
      await _drainReady(owner);
      await _scheduleWake(owner);
    } finally {
      _draining.remove(owner);
    }
  }

  Future<void> _drainReady(String owner) async {
    while (!_disposed && !_parked.contains(owner)) {
      final now = _now();
      final blockedUntil = _cooldownUntil[owner];
      if (blockedUntil != null && now.isBefore(blockedUntil)) return;
      final action = await _store.nextReady(owner, now.millisecondsSinceEpoch);
      if (action == null) return;
      await _replay(action);
      // A queue-cooldown failure returns immediately; a row retry or a
      // success keeps the loop moving to the next ready row.
      if (_cooldownUntil[owner]?.isAfter(_now()) ?? false) return;
    }
  }

  /// Arms [owner]'s wake for the moment its queue can move again: the later
  /// of the cooldown's end and the first pending row's backoff.
  Future<void> _scheduleWake(String owner) async {
    final due = await _store.nextPendingAt(owner);
    _wakes.remove(owner)?.cancel();
    if (due == null) return;
    final cooldownEnd = _cooldownUntil[owner]?.millisecondsSinceEpoch ?? 0;
    _wakeAt(
      owner,
      DateTime.fromMillisecondsSinceEpoch(math.max(due, cooldownEnd)),
    );
  }

  void _wakeAt(String owner, DateTime at) {
    if (_disposed || _parked.contains(owner)) return;
    _wakes.remove(owner)?.cancel();
    _wakes[owner] = Timer(at.difference(_now()), () {
      _wakes.remove(owner);
      log('action queue: wake-up drain');
      unawaited(drain(owner));
    });
  }

  /// Runs [ActionStore.recoverInterrupted] once per queue; a failed attempt
  /// is retried by the next drain instead of being replayed to every caller.
  Future<void> _recoverOnce() =>
      _recovery ??= _recover().catchError((Object error, StackTrace stack) {
        _recovery = null;
        Error.throwWithStackTrace(error, stack);
      });

  /// [_recoverOnce], arming [owner]'s wake when it fails: the next drain
  /// retries it, and no outside event may come to start one (a locked
  /// database left the rows waiting for the next resume).
  Future<void> _recoverFor(String owner) async {
    try {
      await _recoverOnce();
    } on Object {
      _wakeAt(owner, _now().add(cooldown));
      rethrow;
    }
  }

  Future<void> _recover() async {
    final (:reset, :dropped) = await _store.recoverInterrupted();
    if (reset + dropped == 0) return;
    log(
      'action queue: $reset interrupted row(s) back to pending, '
      '$dropped superseded by a newer intent',
    );
  }

  Future<void> _replay(StoredAction action) async {
    final handler = _handlers[action.type];
    if (handler == null) {
      // Unknown type (e.g. from a newer build) — drop visibly rather than
      // spin on a row that can never succeed.
      await _store.markFailed(action.id);
      telemetry.dropped++;
      return;
    }
    // Dropped between nextReady and here: the user took the intent back.
    if (!await _store.markRunning(action.id)) return;
    try {
      await handler(action);
      await _store.delete(action.id);
      telemetry.replayed++;
    } on Object catch (error) {
      await _handleFailure(action, error);
    }
  }

  Future<void> _handleFailure(StoredAction action, Object error) async {
    if (_classify(error) == RetryScope.queueCooldown) {
      final hint = error is ApiRateLimited ? error.retryAfter : null;
      _cooldownUntil[action.owner] = _now().add(hint ?? cooldown);
      await _store.markPending(action.id);
      return;
    }
    final attempt = action.attempt + 1;
    if (attempt >= maxAttempts) {
      await _store.markFailed(action.id);
      telemetry.dropped++;
      return;
    }
    await _store.markPending(
      action.id,
      attempt: attempt,
      nextAttemptAtMs: _now().add(rowBackoff * attempt).millisecondsSinceEpoch,
    );
  }

  /// Network/timeout/429/5xx pause the queue; business rejections (4xx,
  /// parse, unauthorized, unknown) retry the single row. [ApiCancelled]
  /// is treated as transient: the replay was interrupted, not rejected.
  static RetryScope _classify(Object error) {
    if (error is ApiCancelled || isConnectivityError(error)) {
      return RetryScope.queueCooldown;
    }
    return RetryScope.row;
  }
}
