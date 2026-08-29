import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';

/// Terminal state of an account-owned write operation.
///
/// A pending value is never treated as server truth. The terminal states are
/// kept in the feature stores long enough for the UI and diagnostics to
/// observe whether the server confirmed, failed, or invalidated the write.
enum MutationStatus { idle, pending, confirmed, failed, cancelled, superseded }

/// The boundary that owns a write operation at the moment it is created.
///
/// The account ID is metadata, not a credential. No token or cookie crosses
/// this boundary.
@immutable
class MutationBoundary {
  const MutationBoundary({
    required this.accountId,
    required this.credentialRevision,
  });

  final String accountId;
  final int credentialRevision;
}

/// Lifecycle owner for one in-flight mutation.
///
/// The owner owns the cancellation signal passed to the transport. Account
/// changes, provider disposal and superseding operations cancel this owner;
/// a transport that ignores cancellation is still fenced by the envelope.
class MutationOwner {
  MutationOwner({required this.id, required this.accountId, CancelToken? token})
    : cancelToken = token ?? CancelToken();

  final String id;
  final String accountId;
  final CancelToken cancelToken;

  bool get isCancelled => cancelToken.isCancelled;

  void cancel() => cancelToken.cancel();
}

/// Immutable identity carried from mutation begin through the server result.
///
/// The exact dedupe key is `(accountId, entityType, entityId, operation)`.
/// [clientMutationId] is local metadata for correlation only; it is never
/// sent as a substitute for server idempotency and never contains a secret.
@immutable
class MutationEnvelope {
  const MutationEnvelope({
    required this.accountId,
    required this.credentialRevision,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.clientMutationId,
    required this.createdAt,
    required this.owner,
    required this.revision,
  });

  final String accountId;
  final int credentialRevision;
  final String entityType;
  final String entityId;
  final String operation;
  final String clientMutationId;
  final DateTime createdAt;
  final MutationOwner owner;
  final int revision;

  String get operationKey => '$accountId|$entityType|$entityId|$operation';

  String get targetKey => '$accountId|$entityType|$entityId';

  CancelToken get cancelToken => owner.cancelToken;

  bool get isCancelled => owner.isCancelled;

  @override
  String toString() =>
      'MutationEnvelope($entityType/$entityId $operation #$revision '
      '$clientMutationId)';
}

enum MutationDiscardReason {
  superseded,
  cancelled,
  stale,
  accountChanged,
  credentialChanged,
  disposed,
}

/// Bounded metadata-only record for a result that was intentionally dropped.
@immutable
class MutationDiscardEvent {
  const MutationDiscardEvent({required this.envelope, required this.reason});

  final MutationEnvelope envelope;
  final MutationDiscardReason reason;
}

/// Small shared ledger for mutation identity, dedupe and ownership.
///
/// Feature stores own confirmed data and presentation state; this class owns
/// only in-flight identity and bounded stale-result telemetry. It does not
/// persist pending operations, so an account switch or process restart cannot
/// replay a write under another account.
class MutationLedger {
  MutationLedger({this.maxDiscardEvents = 64, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final int maxDiscardEvents;
  final DateTime Function() _now;
  final Map<String, MutationEnvelope> _active = {};
  final List<MutationDiscardEvent> _discardEvents = [];
  int _sequence = 0;
  bool _disposed = false;

  int get revisionNow => _sequence;

  List<MutationDiscardEvent> get discardEvents =>
      List.unmodifiable(_discardEvents);

  bool get isDisposed => _disposed;

  MutationEnvelope? activeFor(String operationKey) => _active[operationKey];

  /// Begins an operation. A pending operation with the exact same key is
  /// suppressed. Other operations targeting the same entity supersede their
  /// old owners before the new envelope is registered.
  MutationEnvelope? begin({
    required MutationBoundary boundary,
    required String entityType,
    required String entityId,
    required String operation,
    String? ownerId,
  }) {
    if (_disposed) return null;
    final operationKey =
        '${boundary.accountId}|$entityType|$entityId|$operation';
    final duplicate = _active[operationKey];
    if (duplicate != null && !duplicate.isCancelled) return null;
    if (duplicate != null) _active.remove(operationKey);

    final targetKey = '${boundary.accountId}|$entityType|$entityId';
    final superseded = _active.entries
        .where((entry) => entry.value.targetKey == targetKey)
        .map((entry) => entry.value)
        .toList(growable: false);
    for (final old in superseded) {
      _active.remove(old.operationKey);
      old.owner.cancel();
      _record(old, MutationDiscardReason.superseded);
    }

    final revision = ++_sequence;
    final clientMutationId = 'mutation-$revision';
    final owner = MutationOwner(
      id: ownerId ?? 'mutation-owner-$revision',
      accountId: boundary.accountId,
    );
    final envelope = MutationEnvelope(
      accountId: boundary.accountId,
      credentialRevision: boundary.credentialRevision,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      clientMutationId: clientMutationId,
      createdAt: _now(),
      owner: owner,
      revision: revision,
    );
    _active[envelope.operationKey] = envelope;
    return envelope;
  }

  bool isActive(MutationEnvelope envelope) =>
      !_disposed &&
      !envelope.isCancelled &&
      identical(_active[envelope.operationKey], envelope);

  void finish(MutationEnvelope envelope) {
    if (identical(_active[envelope.operationKey], envelope)) {
      _active.remove(envelope.operationKey);
    }
  }

  void discard(MutationEnvelope envelope, MutationDiscardReason reason) {
    if (identical(_active[envelope.operationKey], envelope)) {
      _active.remove(envelope.operationKey);
    }
    if (reason != MutationDiscardReason.superseded) envelope.owner.cancel();
    _record(envelope, reason);
  }

  void cancelAll(MutationDiscardReason reason) {
    final active = _active.values.toList(growable: false);
    _active.clear();
    for (final envelope in active) {
      envelope.owner.cancel();
      _record(envelope, reason);
    }
  }

  void dispose() {
    if (_disposed) return;
    cancelAll(MutationDiscardReason.disposed);
    _disposed = true;
  }

  /// Reopens the ledger after Riverpod rebuilds a retained Notifier.  The
  /// active set stays empty, so no pending mutation is resurrected; bounded
  /// discard telemetry and the monotonic sequence remain available to the
  /// replacement account boundary.
  void reopen() {
    _disposed = false;
  }

  void _record(MutationEnvelope envelope, MutationDiscardReason reason) {
    if (_discardEvents.length == maxDiscardEvents) {
      _discardEvents.removeAt(0);
    }
    _discardEvents.add(
      MutationDiscardEvent(envelope: envelope, reason: reason),
    );
  }
}
