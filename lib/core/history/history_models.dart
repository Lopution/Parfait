/// The two content kinds that can be resumed from the local browsing history.
enum HistoryContentType {
  illust('illust'),
  novel('novel');

  const HistoryContentType(this.storageValue);

  final String storageValue;

  static HistoryContentType fromStorage(Object? value) {
    for (final type in values) {
      if (type.storageValue == value) return type;
    }
    throw FormatException('unknown history content type: $value');
  }
}

/// Compact metadata stored with a history row.
///
/// This deliberately contains display fields plus flattened tag search text
/// only. Full Pixiv JSON, captions, novel bodies and credentials never enter
/// the history database.
class HistorySnapshot {
  const HistorySnapshot({
    required this.title,
    required this.authorName,
    this.authorId,
    this.coverUrl,
    this.contentVersion,
    this.anchorParagraphId,
    this.anchorOffset,
    this.tagsText,
  });

  final String title;
  final String authorName;
  final int? authorId;
  final String? coverUrl;
  final String? contentVersion;
  final String? anchorParagraphId;
  final int? anchorOffset;

  /// Newline-delimited original and translated tag names for local search.
  /// Null on rows recorded before schema v3 or works without tags.
  final String? tagsText;

  HistorySnapshot copyWith({
    String? title,
    String? authorName,
    Object? authorId = _unset,
    Object? coverUrl = _unset,
    Object? contentVersion = _unset,
    Object? anchorParagraphId = _unset,
    Object? anchorOffset = _unset,
    Object? tagsText = _unset,
  }) {
    return HistorySnapshot(
      title: title ?? this.title,
      authorName: authorName ?? this.authorName,
      authorId: identical(authorId, _unset) ? this.authorId : authorId as int?,
      coverUrl: identical(coverUrl, _unset)
          ? this.coverUrl
          : coverUrl as String?,
      contentVersion: identical(contentVersion, _unset)
          ? this.contentVersion
          : contentVersion as String?,
      anchorParagraphId: identical(anchorParagraphId, _unset)
          ? this.anchorParagraphId
          : anchorParagraphId as String?,
      anchorOffset: identical(anchorOffset, _unset)
          ? this.anchorOffset
          : anchorOffset as int?,
      tagsText: identical(tagsText, _unset)
          ? this.tagsText
          : tagsText as String?,
    );
  }

  static const _unset = Object();
}

/// One account-scoped row in the local history index.
class HistoryRecord {
  const HistoryRecord({
    this.rowId,
    required this.accountId,
    required this.contentType,
    required this.contentId,
    required this.lastViewedAt,
    required this.snapshot,
    this.visibleDuration = Duration.zero,
    this.snapshotVersion = 1,
  });

  final int? rowId;
  final String accountId;
  final HistoryContentType contentType;
  final int contentId;
  final DateTime lastViewedAt;
  final HistorySnapshot snapshot;
  final Duration visibleDuration;
  final int snapshotVersion;

  /// Throws [ArgumentError] unless the history table takes this row's
  /// content: a positive id and a snapshot version from 1. The account is
  /// the writer's to check (an import rewrites it).
  void checkStorable() {
    if (contentId <= 0) throw ArgumentError.value(contentId, 'contentId');
    if (snapshotVersion < 1) {
      throw ArgumentError.value(snapshotVersion, 'snapshotVersion');
    }
  }

  Map<String, Object?> toColumns() {
    return {
      'account_id': accountId,
      'content_type': contentType.storageValue,
      'content_id': contentId,
      'last_viewed_at': lastViewedAt.toUtc().microsecondsSinceEpoch,
      'title': snapshot.title,
      'author_name': snapshot.authorName,
      'author_id': snapshot.authorId,
      'cover_url': snapshot.coverUrl,
      'content_version': snapshot.contentVersion,
      'anchor_paragraph_id': snapshot.anchorParagraphId,
      'anchor_offset': snapshot.anchorOffset,
      'visible_duration_ms': visibleDuration.inMilliseconds,
      'snapshot_version': snapshotVersion,
      'tags_text': snapshot.tagsText,
    };
  }

  factory HistoryRecord.fromRow(Map<String, Object?> row) {
    final rawTimestamp = row['last_viewed_at'];
    final rawContentId = row['content_id'];
    if (rawTimestamp is! num || rawContentId is! num) {
      throw const FormatException('history row has invalid id or timestamp');
    }
    final accountId = row['account_id'];
    final title = row['title'];
    final authorName = row['author_name'];
    if (accountId is! String || title is! String || authorName is! String) {
      throw const FormatException('history row has invalid display metadata');
    }
    final rawTagsText = row['tags_text'];
    if (rawTagsText is! String?) {
      throw const FormatException('history row has invalid tags text');
    }
    final rawDuration = row['visible_duration_ms'];
    final rawSnapshotVersion = row['snapshot_version'];
    return HistoryRecord(
      rowId: (row['row_id'] as num?)?.toInt(),
      accountId: accountId,
      contentType: HistoryContentType.fromStorage(row['content_type']),
      contentId: rawContentId.toInt(),
      lastViewedAt: DateTime.fromMicrosecondsSinceEpoch(
        rawTimestamp.toInt(),
        isUtc: true,
      ),
      snapshot: HistorySnapshot(
        title: title,
        authorName: authorName,
        authorId: (row['author_id'] as num?)?.toInt(),
        coverUrl: row['cover_url'] as String?,
        contentVersion: row['content_version'] as String?,
        anchorParagraphId: row['anchor_paragraph_id'] as String?,
        anchorOffset: (row['anchor_offset'] as num?)?.toInt(),
        tagsText: rawTagsText,
      ),
      visibleDuration: Duration(
        milliseconds: rawDuration is num ? rawDuration.toInt() : 0,
      ),
      snapshotVersion: rawSnapshotVersion is num
          ? rawSnapshotVersion.toInt()
          : 1,
    );
  }

  HistoryRecord copyWith({
    DateTime? lastViewedAt,
    HistorySnapshot? snapshot,
    Duration? visibleDuration,
    int? snapshotVersion,
  }) {
    return HistoryRecord(
      rowId: rowId,
      accountId: accountId,
      contentType: contentType,
      contentId: contentId,
      lastViewedAt: lastViewedAt ?? this.lastViewedAt,
      snapshot: snapshot ?? this.snapshot,
      visibleDuration: visibleDuration ?? this.visibleDuration,
      snapshotVersion: snapshotVersion ?? this.snapshotVersion,
    );
  }
}

/// Pending Pixiv history work. Duration is retained so account switches and
/// offline failures do not lose the visibility interval before a retry.
class PixivHistoryOutboxEntry {
  const PixivHistoryOutboxEntry({
    required this.accountId,
    required this.contentType,
    required this.contentId,
    required this.unsubmittedDuration,
    required this.lastViewedAt,
    required this.attempts,
    this.nextAttemptAt,
  });

  final String accountId;
  final HistoryContentType contentType;
  final int contentId;
  final Duration unsubmittedDuration;
  final DateTime lastViewedAt;
  final int attempts;
  final DateTime? nextAttemptAt;

  factory PixivHistoryOutboxEntry.fromRow(Map<String, Object?> row) {
    final accountId = row['account_id'];
    final contentId = row['content_id'];
    final duration = row['duration_ms'];
    final lastViewedAt = row['last_viewed_at'];
    if (accountId is! String ||
        contentId is! num ||
        duration is! num ||
        lastViewedAt is! num) {
      throw const FormatException('history outbox row is malformed');
    }
    final nextAttempt = row['next_attempt_at'];
    return PixivHistoryOutboxEntry(
      accountId: accountId,
      contentType: HistoryContentType.fromStorage(row['content_type']),
      contentId: contentId.toInt(),
      unsubmittedDuration: Duration(milliseconds: duration.toInt()),
      lastViewedAt: DateTime.fromMicrosecondsSinceEpoch(
        lastViewedAt.toInt(),
        isUtc: true,
      ),
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: nextAttempt is num
          ? DateTime.fromMicrosecondsSinceEpoch(
              nextAttempt.toInt(),
              isUtc: true,
            )
          : null,
    );
  }
}

class HistoryPageResult {
  const HistoryPageResult({required this.records, required this.hasMore});

  final List<HistoryRecord> records;
  final bool hasMore;
}

class HistorySyncException implements Exception {
  const HistorySyncException(this.failures);

  final List<Object> failures;

  @override
  String toString() => 'HistorySyncException(${failures.length} failure(s))';
}

class HistoryAccountChangedException implements Exception {
  const HistoryAccountChangedException(this.accountId);

  final String accountId;

  @override
  String toString() => 'HistoryAccountChangedException($accountId)';
}

/// Debounce window applied to interactive local history search input before
/// re-querying SQLite.
const historySearchDebounce = Duration(milliseconds: 180);

/// Maximum number of distinct whitespace-separated tokens applied in one
/// local SQLite history search, keeping SQL predicate depth bounded.
const maxHistorySearchTokens = 12;

final _historyQueryWhitespace = RegExp(r'[\s\u3000]+');

/// Splits [raw] on half- and full-width whitespace, deduplicating tokens
/// case-insensitively in order and capping at [maxHistorySearchTokens].
List<String> tokenizeHistoryQuery(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];
  final tokens = <String>[];
  final seen = <String>{};
  for (final piece in trimmed.split(_historyQueryWhitespace)) {
    if (piece.isEmpty) continue;
    if (!seen.add(piece.toLowerCase())) continue;
    tokens.add(piece);
    if (tokens.length >= maxHistorySearchTokens) break;
  }
  return tokens;
}

/// Canonical query string used in [HistoryFeedQuery] keys so trailing or
/// repeated whitespace never spawns redundant feed providers.
String normalizeHistoryQuery(String raw) => tokenizeHistoryQuery(raw).join(' ');

/// Immutable selector for a history feed page stream.
class HistoryFeedQuery {
  HistoryFeedQuery({
    required this.accountId,
    this.contentType,
    String query = '',
  }) : query = normalizeHistoryQuery(query);

  final String accountId;
  final HistoryContentType? contentType;
  final String query;

  bool get hasFilter => contentType != null || query.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is HistoryFeedQuery &&
      other.accountId == accountId &&
      other.contentType == contentType &&
      other.query == query;

  @override
  int get hashCode => Object.hash(accountId, contentType, query);

  @override
  String toString() =>
      'HistoryFeedQuery(accountId: $accountId, '
      'contentType: $contentType, query: $query)';
}
