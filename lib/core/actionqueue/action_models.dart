/// Row model and shared enums for the persistent offline action queue.
/// See `action_queue.dart` for drain semantics and `action_store.dart` for
/// the persistence boundary.
library;

import 'dart:convert';

/// Lifecycle of one queued action row.
enum ActionStatus {
  pending('pending'),
  running('running'),
  failed('failed');

  const ActionStatus(this.dbValue);

  final String dbValue;

  static ActionStatus fromDb(String value) {
    for (final status in values) {
      if (status.dbValue == value) return status;
    }
    throw ArgumentError('unknown action status $value');
  }
}

/// How a failed replay is retried.
///
/// [queueCooldown] covers connectivity-class failures (network, timeout,
/// 429, 5xx): the row goes back to pending untouched and the whole owner
/// queue pauses for a cooldown. [row] covers business rejections (4xx,
/// parse, unknown): only that row backs off and its attempt counter grows.
enum RetryScope { queueCooldown, row }

/// One decoded `action_queue` row.
class StoredAction {
  const StoredAction({
    required this.id,
    required this.owner,
    required this.type,
    required this.dedupeKey,
    required this.payload,
    required this.status,
    required this.attempt,
    required this.createdAt,
    this.nextAttemptAt,
  });

  final int id;

  /// The account this action belongs to.
  final String owner;

  /// Handler key, e.g. `bookmark.add`.
  final String type;

  /// Coalescing key, e.g. `bookmark.add:12345` — one pending row per key.
  final String dedupeKey;

  /// JSON-encoded arguments; the owning handler decodes it.
  final String payload;

  final ActionStatus status;

  /// Failed replay attempts so far (row-scope retries only).
  final int attempt;

  /// Earliest epoch-ms at which the row may run again; null = ready.
  final int? nextAttemptAt;

  /// Epoch-ms when the action was enqueued.
  final int createdAt;

  /// Decoded payload for handlers. Malformed JSON is the handler's row
  /// failure — it surfaces as a [RetryScope.row] retry, not a crash.
  Map<String, Object?> decodePayload() =>
      jsonDecode(payload) as Map<String, Object?>;

  StoredAction copyWith({
    ActionStatus? status,
    int? attempt,
    int? nextAttemptAt,
    bool clearNextAttempt = false,
  }) {
    return StoredAction(
      id: id,
      owner: owner,
      type: type,
      dedupeKey: dedupeKey,
      payload: payload,
      status: status ?? this.status,
      attempt: attempt ?? this.attempt,
      nextAttemptAt: clearNextAttempt
          ? null
          : nextAttemptAt ?? this.nextAttemptAt,
      createdAt: createdAt,
    );
  }
}

/// Cumulative counters surfaced for diagnostics. Rows dropped after
/// exhausting attempts stay in the table for observation until the next
/// successful drain window or account cleanup.
class ActionTelemetry {
  /// Actions that replayed to a successful handler return.
  int replayed = 0;

  /// Actions that exhausted [ActionQueue.maxAttempts] row retries.
  int dropped = 0;
}
