/// Watchlist (追更) domain models. A watchlist entry is always a *series*:
/// the manga list tracks illust series, the novel list tracks novel series —
/// matching PixEz's `/v1/watchlist/{manga,novel}` contract.
library;

import 'package:flutter/foundation.dart';

import '../mutation/mutation_models.dart';
import '../network/pixiv_http_client.dart';

/// The two series families a watchlist can follow.
enum WatchlistType {
  manga('manga'),
  novel('novel');

  const WatchlistType(this.apiValue);

  /// Path segment of `/v1/watchlist/{apiValue}` and of the action-queue
  /// dedupe key.
  final String apiValue;

  static WatchlistType fromApiValue(Object? value) {
    for (final type in values) {
      if (type.apiValue == value) return type;
    }
    return WatchlistType.manga;
  }
}

/// Identity of one watchlistable series.
@immutable
class WatchlistKey {
  const WatchlistKey(this.type, this.seriesId);

  final WatchlistType type;
  final int seriesId;

  /// Target-scoped dedupe key shared by the action queue and diagnostics.
  String get dedupeKey => 'watchlist:${type.apiValue}:$seriesId';

  @override
  bool operator ==(Object other) =>
      other is WatchlistKey && other.type == type && other.seriesId == seriesId;

  @override
  int get hashCode => Object.hash(type, seriesId);

  @override
  String toString() => 'WatchlistKey(${type.apiValue}:$seriesId)';
}

/// One row of `GET /v1/watchlist/{manga,novel}`.
@immutable
class WatchlistSeriesEntry {
  const WatchlistSeriesEntry({
    required this.id,
    required this.type,
    required this.title,
    required this.userId,
    required this.userName,
    this.userAvatarUrl,
    this.latestContentId,
    this.lastPublishedContentDatetime,
    this.publishedContentCount,
    this.coverUrl,
    this.maskText,
  });

  /// Series id — the same id the illust/novel series pages open.
  final int id;
  final WatchlistType type;
  final String title;
  final int userId;
  final String userName;
  final String? userAvatarUrl;

  /// `latest_content_id` — the "new content" badge compares this against
  /// the locally stored read cursor.
  final int? latestContentId;

  /// `last_published_content_datetime`, kept raw for display.
  final String? lastPublishedContentDatetime;

  /// `published_content_count`.
  final int? publishedContentCount;

  /// `url` — Pixiv's pre-cropped cover image.
  final String? coverUrl;

  /// `mask_text` — e.g. view-restriction notice.
  final String? maskText;

  WatchlistKey get key => WatchlistKey(type, id);
}

/// One page of a watchlist.
class WatchlistPage {
  const WatchlistPage({required this.entries, required this.nextUrl});

  final List<WatchlistSeriesEntry> entries;
  final String? nextUrl;
}

enum WatchlistOpKind { add, delete }

/// In-flight watchlist mutation handle (same contract as [BookmarkOp]).
@immutable
class WatchlistOp {
  const WatchlistOp({
    required this.key,
    required this.envelope,
    required this.kind,
  });

  final WatchlistKey key;
  final MutationEnvelope envelope;
  final WatchlistOpKind kind;

  int get revision => envelope.revision;

  String get accountId => envelope.accountId;

  CancelToken get cancelToken => envelope.cancelToken;

  bool get isCancelled => envelope.isCancelled;

  @override
  String toString() => 'WatchlistOp(#$revision ${kind.name} $key)';
}

/// Confirmed + pending watchlist state for one series.
@immutable
class WatchlistEntry {
  const WatchlistEntry({
    required this.added,
    this.pending,
    this.error,
    this.confirmedRevision,
    this.status = MutationStatus.idle,
  });

  /// Last confirmed value; never flipped before the operation commits.
  final bool added;
  final WatchlistOp? pending;
  final Object? error;
  final int? confirmedRevision;
  final MutationStatus status;

  bool get isPending => status == MutationStatus.pending && pending != null;
}
