import 'package:flutter/foundation.dart';

import '../mutation/mutation_models.dart';
import '../network/pixiv_http_client.dart';

/// Entity types that support bookmarks. Novel is reserved for the Novel
/// surfaces; this task only validates the Illust path (design §Compatibility).
enum BookmarkEntityType { illust, novel }

/// Bookmark visibility, mirroring the Pixiv `restrict` values.
enum BookmarkRestrict { public, private }

/// Wire value for the Pixiv `restrict` parameter.
String bookmarkRestrictWire(BookmarkRestrict restrict) =>
    restrict == BookmarkRestrict.private ? 'private' : 'public';

/// Canonical identity of a bookmarkable work.
@immutable
class BookmarkKey {
  const BookmarkKey(this.type, this.id);

  final BookmarkEntityType type;
  final int id;

  @override
  bool operator ==(Object other) =>
      other is BookmarkKey && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => 'BookmarkKey($type, $id)';
}

enum BookmarkOpKind { add, delete }

/// In-flight mutation handle carrying the store revision at which the
/// operation began. Late completions whose revision no longer matches the
/// pending entry are dropped (R5: 晚到响应不触发重复 mutation).
@immutable
class BookmarkOp {
  const BookmarkOp({
    required this.key,
    required this.envelope,
    required this.kind,
    required this.restrict,
  });

  final BookmarkKey key;
  final MutationEnvelope envelope;
  final BookmarkOpKind kind;
  final BookmarkRestrict restrict;

  int get revision => envelope.revision;

  String get accountId => envelope.accountId;

  CancelToken get cancelToken => envelope.cancelToken;

  bool get isCancelled => envelope.isCancelled;

  @override
  String toString() =>
      'BookmarkOp(#$revision ${kind.name} $key ${restrict.name})';
}

/// Confirmed + pending bookmark state for one key.
@immutable
class BookmarkEntry {
  const BookmarkEntry({
    required this.bookmarked,
    this.restrict,
    this.pending,
    this.error,
    this.confirmedRevision,
    this.status = MutationStatus.idle,
  });

  /// Last confirmed value. Never flipped before its operation commits
  /// (R4: 非 optimistic).
  final bool bookmarked;

  /// Visibility of the current bookmark (null when unknown/not bookmarked).
  final BookmarkRestrict? restrict;

  /// Operation in flight, if any.
  final BookmarkOp? pending;

  /// Failure of the most recent operation, cleared by the next begin/commit.
  final Object? error;

  /// Store revision at the last locally confirmed change. Remote snapshots
  /// captured before this revision are stale and ignored (R2).
  final int? confirmedRevision;

  /// Observable mutation lifecycle. The confirmed bookmark value remains the
  /// source of truth while [status] is pending, failed, cancelled or stale.
  final MutationStatus status;

  bool get isPending => status == MutationStatus.pending && pending != null;

  BookmarkEntry copyWith({
    bool? bookmarked,
    BookmarkRestrict? restrict,
    BookmarkOp? pending,
    Object? error,
    int? confirmedRevision,
    MutationStatus? status,
    bool clearRestrict = false,
    bool clearPending = false,
    bool clearError = false,
  }) {
    return BookmarkEntry(
      bookmarked: bookmarked ?? this.bookmarked,
      restrict: clearRestrict ? null : (restrict ?? this.restrict),
      pending: clearPending ? null : (pending ?? this.pending),
      error: clearError ? null : (error ?? this.error),
      confirmedRevision: confirmedRevision ?? this.confirmedRevision,
      status: status ?? this.status,
    );
  }

  @override
  String toString() =>
      'BookmarkEntry(bookmarked: $bookmarked, restrict: $restrict, '
      'pending: $pending, status: $status, error: $error, '
      'confirmed: $confirmedRevision)';
}
