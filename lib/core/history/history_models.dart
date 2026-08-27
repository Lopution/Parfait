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
/// This deliberately contains display fields only. Full Pixiv JSON, captions,
/// tags and credentials never enter the history database.
class HistorySnapshot {
  const HistorySnapshot({
    required this.title,
    required this.authorName,
    this.authorId,
    this.coverUrl,
    this.contentVersion,
    this.anchorParagraphId,
    this.anchorOffset,
  });

  final String title;
  final String authorName;
  final int? authorId;
  final String? coverUrl;
  final String? contentVersion;
  final String? anchorParagraphId;
  final int? anchorOffset;

  HistorySnapshot copyWith({
    String? title,
    String? authorName,
    Object? authorId = _unset,
    Object? coverUrl = _unset,
    Object? contentVersion = _unset,
    Object? anchorParagraphId = _unset,
    Object? anchorOffset = _unset,
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
  const HistoryPageResult({
    required this.records,
    required this.total,
    required this.offset,
    required this.limit,
  });

  final List<HistoryRecord> records;
  final int total;
  final int offset;
  final int limit;

  bool get hasMore => offset + records.length < total;
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
