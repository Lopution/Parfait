import 'package:flutter/foundation.dart';

import '../mutation/mutation_models.dart';
import '../network/pixiv_http_client.dart';

/// Visibility used when adding a Pixiv follow relationship.
enum FollowRestrict { public, private }

String followRestrictWire(FollowRestrict restrict) =>
    restrict == FollowRestrict.private ? 'private' : 'public';

/// One remote follow observation: what a payload claims for [userId].
typedef FollowSnapshot = ({
  int userId,
  bool? followed,
  FollowRestrict? restrict,
});

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
    this.wish,
    this.error,
    this.confirmedRevision,
    this.status = MutationStatus.idle,
  });

  /// The last confirmed server value. It does not change while an operation
  /// is in flight; the UI shows [shown] instead.
  final bool followed;
  final FollowRestrict? restrict;

  /// Operation in flight or queued offline, if any.
  final FollowOperation? pending;

  /// The value the user last chose while it is unconfirmed — the
  /// BookmarkEntry.wish rule.
  final bool? wish;
  final Object? error;
  final int? confirmedRevision;

  final MutationStatus status;

  /// What the UI shows: the user's wish at once, the confirmed value after.
  bool get shown => wish ?? followed;

  /// In flight or queued offline.
  bool get isPending =>
      pending != null &&
      (status == MutationStatus.pending || status == MutationStatus.queued);

  bool get isQueued => status == MutationStatus.queued && pending != null;

  /// A request is pending or a wish still awaits its follow-up request.
  bool get isUnsettled => isPending || wish != null;

  FollowEntry copyWith({
    bool? followed,
    FollowRestrict? restrict,
    FollowOperation? pending,
    bool? wish,
    Object? error,
    int? confirmedRevision,
    MutationStatus? status,
    bool clearRestrict = false,
    bool clearPending = false,
    bool clearWish = false,
    bool clearError = false,
  }) {
    return FollowEntry(
      followed: followed ?? this.followed,
      restrict: clearRestrict ? null : (restrict ?? this.restrict),
      pending: clearPending ? null : (pending ?? this.pending),
      wish: clearWish ? null : (wish ?? this.wish),
      error: clearError ? null : (error ?? this.error),
      confirmedRevision: confirmedRevision ?? this.confirmedRevision,
      status: status ?? this.status,
    );
  }

  @override
  String toString() =>
      'FollowEntry(followed: $followed, wish: $wish, restrict: $restrict, '
      'pending: $pending, status: $status, error: $error, '
      'confirmed: $confirmedRevision)';
}
