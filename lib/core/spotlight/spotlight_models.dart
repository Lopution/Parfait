/// pixivision spotlight domain models: the `/v1/spotlight/articles` list
/// entries and the structured article body produced by `article_parser`.
library;

import '../entity/json_read.dart';

/// `/v1/spotlight/articles?category=` selector. The wire value is the enum
/// name; `all` is Pixiv's mixed feed, not a client-side union.
enum SpotlightCategory { all, illust, manga }

/// One spotlight article entry from `/v1/spotlight/articles`.
class SpotlightArticle {
  const SpotlightArticle({
    required this.id,
    required this.title,
    required this.articleUrl,
    this.pureTitle = '',
    this.thumbnailUrl,
    this.publishDate = '',
    this.category = '',
    this.subcategoryLabel = '',
  });

  final int id;
  final String title;
  final String pureTitle;

  /// `article_url` — the www.pixivision.net page fetched for in-app reading.
  final String articleUrl;

  /// `thumbnail` — CDN image for list rows (not a pximg host).
  final String? thumbnailUrl;

  /// `publish_date` — already display-formatted on the wire.
  final String publishDate;
  final String category;
  final String subcategoryLabel;

  factory SpotlightArticle.fromJson(Map<String, dynamic> json) {
    final id = readPositiveInt(json['id']);
    final title = readOptionalString(json['title']);
    final articleUrl = readOptionalString(json['article_url']);
    if (id == null || title == null || articleUrl == null) {
      throw const FormatException(
        'spotlight article is missing required fields',
      );
    }
    return SpotlightArticle(
      id: id,
      title: title,
      pureTitle: readOptionalString(json['pure_title']) ?? '',
      articleUrl: articleUrl,
      thumbnailUrl: readOptionalString(json['thumbnail']),
      publishDate: readOptionalString(json['publish_date']) ?? '',
      category: readOptionalString(json['category']) ?? '',
      subcategoryLabel: readOptionalString(json['subcategory_label']) ?? '',
    );
  }
}
