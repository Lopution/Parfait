/// Row model and shared enums for the persistent offline action queue.
/// See `action_queue.dart` for drain semantics and `action_store.dart` for
/// the persistence boundary.
library;

import 'dart:convert';

import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';

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

/// Well-known action types. New mutation families add a constant here and
/// register a handler in `action_bootstrap.dart`.
abstract final class ActionTypes {
  static const bookmarkAdd = 'bookmark.add';
  static const bookmarkDelete = 'bookmark.delete';
  static const followAdd = 'follow.add';
  static const followDelete = 'follow.delete';
  static const watchlistAdd = 'watchlist.add';
  static const watchlistDelete = 'watchlist.delete';
}

/// Connectivity-class failures — the reason an action was queued offline
/// and the reason a replay pauses the whole queue. Business rejections
/// (4xx, unauthorized, parse errors) never qualify: they failed for a
/// reason the network cannot fix.
bool isConnectivityError(Object error) {
  // The transport taxonomy owns classification so callers see the same
  // verdict no matter which layer raised the failure: a raw ladder/
  // resolver exception (NetworkFailureException, SecureResolutionException,
  // an unwrapped rhttp error) classifies identically to its ApiNetworkError
  // wrapper. certificateMismatch stays terminal — a swapped certificate is
  // a visible security failure, never a queueable retry. cancelled, auth,
  // parse and redirect outcomes are business verdicts the network cannot
  // fix.
  final failure = TransportFailureClassifier.classify(error);
  return switch (failure.kind) {
    NetworkFailureKind.dns ||
    NetworkFailureKind.connect ||
    NetworkFailureKind.timeout ||
    NetworkFailureKind.reset ||
    NetworkFailureKind.tlsHandshake ||
    NetworkFailureKind.rateLimit => true,
    // A delivered 5xx is a server-side transient — safe to replay later.
    // 4xx/3xx stay visible business failures.
    NetworkFailureKind.http => switch (failure.cause) {
      ApiHttpError(:final statusCode) => statusCode >= 500,
      NetworkRouteProbeException(:final statusCode) => statusCode >= 500,
      _ => false,
    },
    // ApiNetworkError is the transport layer's own declaration of a
    // network failure — an unclassifiable cause stays queueable (the
    // historical blanket rule). Causes that classify to a terminal kind
    // (certificateMismatch, auth, redirect) matched an arm above and
    // never reach here.
    NetworkFailureKind.unknown => error is ApiNetworkError,
    _ => false,
  };
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
