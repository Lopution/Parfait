/// Illust-series domain models shared by the series page, the profile
/// series list and the detail-page context section.
library;

import '../entity/json_read.dart';

/// One illust series (`/v1/illust/series` detail and
/// `/v1/user/illust-series` entries share this entity).
///
/// Not every payload carries every field: user-series entries omit
/// `watchlistAdded`/`isConcluded`/`latestContentId`, so those stay nullable
/// and [mergeOver] keeps previously observed values.
class IllustSeriesEntity {
  const IllustSeriesEntity({
    required this.id,
    required this.title,
    required this.userId,
    required this.userName,
    this.caption = '',
    this.coverUrl,
    this.workCount,
    this.watchlistAdded,
    this.isConcluded,
    this.latestContentId,
    this.firstContentId,
  });

  final int id;
  final String title;
  final String caption;
  final int userId;
  final String userName;

  /// `cover_image_urls.link_360` (falling back to the larger variant).
  final String? coverUrl;

  /// `series_work_count` — the "全 N 话" label source.
  final int? workCount;

  /// `watchlist_added` — only the series detail payload carries it.
  final bool? watchlistAdded;

  /// `is_concluded` — only the series detail payload carries it.
  final bool? isConcluded;

  /// Id of the newest work in the series (`illust_series_latest_illust.id`).
  final int? latestContentId;

  /// Id of the first work in the series (`illust_series_first_illust.id`) —
  /// the series page's「开始阅读」target. Only the series-works payload
  /// carries it; user-series entries omit it and keep the merged value.
  final int? firstContentId;

  /// Merge rule for the shared store: incoming non-empty values win, while
  /// fields the payload did not carry keep the previously observed value.
  IllustSeriesEntity mergeOver(IllustSeriesEntity previous) {
    return IllustSeriesEntity(
      id: id,
      title: title.isNotEmpty ? title : previous.title,
      caption: caption.isNotEmpty ? caption : previous.caption,
      userId: userId,
      userName: userName.isNotEmpty ? userName : previous.userName,
      coverUrl: coverUrl ?? previous.coverUrl,
      workCount: workCount ?? previous.workCount,
      watchlistAdded: watchlistAdded ?? previous.watchlistAdded,
      isConcluded: isConcluded ?? previous.isConcluded,
      latestContentId: latestContentId ?? previous.latestContentId,
      firstContentId: firstContentId ?? previous.firstContentId,
    );
  }

  /// Parses one `illust_series_detail` / `illust_series_details[]` object.
  /// [latestContentId] and [firstContentId] are supplied by the caller when
  /// the payload carries them as sibling objects rather than detail fields.
  factory IllustSeriesEntity.fromJson(
    Map<String, dynamic> json, {
    int? latestContentId,
    int? firstContentId,
  }) {
    final id = readPositiveInt(json['id']);
    final title = readOptionalString(json['title']);
    final userJson = json['user'];
    if (id == null || title == null || userJson is! Map<String, dynamic>) {
      throw const FormatException(
        'illust series entry is missing required fields',
      );
    }
    final userId = readPositiveInt(userJson['id']);
    if (userId == null) {
      throw const FormatException('illust series user id is invalid');
    }
    final covers = json['cover_image_urls'];
    return IllustSeriesEntity(
      id: id,
      title: title,
      caption: readOptionalString(json['caption']) ?? '',
      userId: userId,
      userName: readOptionalString(userJson['name']) ?? '',
      coverUrl: covers is Map<String, dynamic>
          ? readFirstString(covers, const ['link_360', 'link_1200'])
          : null,
      workCount: readPositiveInt(json['series_work_count']),
      watchlistAdded: json['watchlist_added'] is bool
          ? json['watchlist_added'] as bool
          : null,
      isConcluded: json['is_concluded'] is bool
          ? json['is_concluded'] as bool
          : null,
      latestContentId:
          latestContentId ?? readPositiveInt(json['latest_content_id']),
      firstContentId:
          firstContentId ?? readPositiveInt(json['first_content_id']),
    );
  }
}

/// Position of one illust inside its series
/// (`/v1/illust-series/illust` response).
class IllustSeriesContext {
  const IllustSeriesContext({
    required this.seriesId,
    this.contentOrder,
    this.prevIllustId,
    this.nextIllustId,
  });

  final int seriesId;

  /// `content_order` — the 1-based position label (第 N 话).
  final int? contentOrder;
  final int? prevIllustId;
  final int? nextIllustId;
}
