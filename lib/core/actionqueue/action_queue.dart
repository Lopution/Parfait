/// Persistent offline action queue. Mutations that fail on connectivity
/// are enqueued per account and replayed serially once the app is back
/// online — see `design.md` (§3) and the Shaft `actionqueue` reference.
///
/// Failure taxonomy (mirrors Shaft's RetryScope split):
/// - [RetryScope.queueCooldown] — network/timeout/429/5xx: the row returns
///   to pending untouched and the whole owner queue sleeps for a cooldown
///   (a 429 `retryAfter` hint overrides the default).
/// - [RetryScope.row] — 4xx/business/unknown rejections: only that row
///   backs off with a growing attempt counter; [maxAttempts] drops it.
library;

import 'dart:async';
import 'dart:convert';

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
  }) {
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
    return _store.enqueue(draft);
  }

  /// Drains [owner]'s ready rows serially, oldest first. Re-entrant calls
  /// are coalesced — a drain already in progress simply continues. A
  /// queue-cooldown failure stops the drain until [cooldown] elapses.
  Future<void> drain(String owner) async {
    if (!_draining.add(owner)) return;
    try {
      while (true) {
        final now = _now();
        final blockedUntil = _cooldownUntil[owner];
        if (blockedUntil != null && now.isBefore(blockedUntil)) return;
        final action = await _store.nextReady(
          owner,
          now.millisecondsSinceEpoch,
        );
        if (action == null) return;
        await _replay(action);
        // A queue-cooldown failure returns immediately; a row retry or a
        // success keeps the loop moving to the next ready row.
        if (_cooldownUntil[owner]?.isAfter(_now()) ?? false) return;
      }
    } finally {
      _draining.remove(owner);
    }
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
    await _store.markRunning(action.id);
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
