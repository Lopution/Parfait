import 'package:flutter/foundation.dart';

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
    required this.revision,
    required this.kind,
    required this.restrict,
  });

  final int userId;
  final int revision;
  final FollowOperationKind kind;
  final FollowRestrict restrict;

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
  });

  /// The last confirmed server value. It does not change while an operation
  /// is in flight, so the UI cannot display a false success.
  final bool followed;
  final FollowRestrict? restrict;
  final FollowOperation? pending;
  final Object? error;
  final int? confirmedRevision;

  bool get isPending => pending != null;

  FollowEntry copyWith({
    bool? followed,
    FollowRestrict? restrict,
    FollowOperation? pending,
    Object? error,
    int? confirmedRevision,
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
    );
  }

  @override
  String toString() =>
      'FollowEntry(followed: $followed, restrict: $restrict, '
      'pending: $pending, error: $error, confirmed: $confirmedRevision)';
}
