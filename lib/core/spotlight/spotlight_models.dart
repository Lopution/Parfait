/// pixivision spotlight domain models: the `/v1/spotlight/articles` list
/// entries and the structured article body produced by `article_parser`.
library;

import '../entity/json_read.dart';
import '../log.dart';

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
    this.publishDate,
    this.category = '',
    this.subcategoryLabel = '',
  });

  final int id;
  final String title;
  final String pureTitle;

  /// `article_url` — the www.pixivision.net page fetched for in-app reading.
  final String articleUrl;

  /// `thumbnail` — the article's cover art on a pximg host, drawn by the
  /// list rows and, in place of the page's own cover, by the article.
  final String? thumbnailUrl;

  /// `publish_date`, parsed at the boundary. Null when the wire string is
  /// missing or does not parse.
  final DateTime? publishDate;
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
    final rawPublishDate = readOptionalString(json['publish_date']);
    final publishDate = rawPublishDate == null
        ? null
        : DateTime.tryParse(rawPublishDate);
    if (rawPublishDate != null && publishDate == null) {
      log('spotlight article $id: unparseable publish_date "$rawPublishDate"');
    }
    return SpotlightArticle(
      id: id,
      title: title,
      pureTitle: readOptionalString(json['pure_title']) ?? '',
      articleUrl: articleUrl,
      thumbnailUrl: readOptionalString(json['thumbnail']),
      publishDate: publishDate,
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
  const SpotlightImage(this.url, {this.cover = false});

  final String url;

  /// The article's eyecatch. The page serves it from embed.pixiv.net — an
  /// image generated per request behind Cloudflare, outside the Pixiv
  /// network policy — so the reader prefers the list entry's pximg
  /// [SpotlightArticle.thumbnailUrl] of the same art.
  final bool cover;
}

/// The `.am__work` artwork card embedded in an article: `/artworks/<id>`
/// link, h3 title, work image and the author line with its avatar.
class SpotlightIllustCard extends SpotlightBlock {
  const SpotlightIllustCard({
    required this.illustId,
    required this.title,
    this.imageUrl,
    this.userName,
    this.userId,
    this.userAvatarUrl,
  });

  final int illustId;
  final String title;
  final String? imageUrl;
  final String? userName;
  final int? userId;
  final String? userAvatarUrl;
}
