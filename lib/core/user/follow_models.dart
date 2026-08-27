import 'package:flutter/foundation.dart';

import '../mutation/mutation_models.dart';
import '../network/pixiv_http_client.dart';

/// Visibility used when adding a Pixiv follow relationship.
enum FollowRestrict { public, private }

String followRestrictWire(FollowRestrict restrict) =>
    restrict == FollowRestrict.private ? 'private' : 'public';

enum FollowOperationKind { add, delete }

/// A single follow mutation and its revision gate.
@immutable
class FollowOperation {
  const FollowOperation({
    required this.userId,
    required this.envelope,
    required this.kind,
    required this.restrict,
  });

  final int userId;
  final MutationEnvelope envelope;
  final FollowOperationKind kind;
  final FollowRestrict restrict;

  int get revision => envelope.revision;

  CancelToken get cancelToken => envelope.cancelToken;

  @override
  String toString() =>
      'FollowOperation(#$revision ${kind.name} user:$userId ${restrict.name})';
}

/// Confirmed and pending follow state for one user.
@immutable
class FollowEntry {
  const FollowEntry({
    required this.followed,
    this.restrict,
    this.pending,
    this.error,
    this.confirmedRevision,
    this.status = MutationStatus.idle,
  });

  /// The last confirmed server value. It does not change while an operation
  /// is in flight, so the UI cannot display a false success.
  final bool followed;
  final FollowRestrict? restrict;
  final FollowOperation? pending;
  final Object? error;
  final int? confirmedRevision;

  final MutationStatus status;

  bool get isPending => status == MutationStatus.pending && pending != null;

  FollowEntry copyWith({
    bool? followed,
    FollowRestrict? restrict,
    FollowOperation? pending,
    Object? error,
    int? confirmedRevision,
    MutationStatus? status,
    bool clearRestrict = false,
    bool clearPending = false,
    bool clearError = false,
  }) {
    return FollowEntry(
      followed: followed ?? this.followed,
      restrict: clearRestrict ? null : (restrict ?? this.restrict),
      pending: clearPending ? null : (pending ?? this.pending),
      error: clearError ? null : (error ?? this.error),
      confirmedRevision: confirmedRevision ?? this.confirmedRevision,
      status: status ?? this.status,
    );
  }

  @override
  String toString() =>
      'FollowEntry(followed: $followed, restrict: $restrict, '
      'pending: $pending, status: $status, error: $error, '
      'confirmed: $confirmedRevision)';
}
