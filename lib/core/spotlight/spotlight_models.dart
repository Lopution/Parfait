/// pixivision spotlight domain models: the `/v1/spotlight/articles` list
/// entries and the structured article body produced by `article_parser`.
library;

import '../entity/json_read.dart';

/// `/v1/spotlight/articles?category=` selector. The wire value is the enum
/// name; `all` is Pixiv's mixed feed, not a client-side union.
enum SpotlightCategory { all, illust, manga }

/// l10n keys for the category selector, resolved via `l10nLookup` in the
/// page (same pattern as `SearchResultTypeWire.labelKey`).
extension SpotlightCategoryLabel on SpotlightCategory {
  String get labelKey => switch (this) {
    SpotlightCategory.all => 'spotlightCategoryAll',
    SpotlightCategory.illust => 'spotlightCategoryIllust',
    SpotlightCategory.manga => 'spotlightCategoryManga',
  };
}

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

/// Structured body of one pixivision article, produced by
/// `parseSpotlightArticle` — the app renders these blocks instead of a
/// full-page webview.
class SpotlightArticleBody {
  const SpotlightArticleBody({
    required this.title,
    this.description,
    required this.blocks,
  });

  final String title;

  /// Lead text from the article header, when present.
  final String? description;
  final List<SpotlightBlock> blocks;
}

sealed class SpotlightBlock {
  const SpotlightBlock();
}

/// A paragraph as ordered text runs; linked runs carry their href so the
/// renderer can route `/artworks/` and `/users/` natively.
class SpotlightParagraph extends SpotlightBlock {
  const SpotlightParagraph(this.segments);

  final List<({String text, String? href})> segments;
}

class SpotlightHeading extends SpotlightBlock {
  const SpotlightHeading(this.text, {required this.level});

  final String text;
  final int level;
}

class SpotlightImage extends SpotlightBlock {
  const SpotlightImage(this.url);

  final String url;
}

/// The `.illust` artwork card embedded in an article: `/artworks/<id>`
/// link, h3 title, thumbnail and the author line.
class SpotlightIllustCard extends SpotlightBlock {
  const SpotlightIllustCard({
    required this.illustId,
    required this.title,
    this.imageUrl,
    this.userName,
    this.userId,
  });

  final int illustId;
  final String title;
  final String? imageUrl;
  final String? userName;
  final int? userId;
}
