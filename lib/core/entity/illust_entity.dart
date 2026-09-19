import 'dart:convert';

import '../settings/app_settings.dart';
import 'json_read.dart';

/// Non-secret value objects describing one Pixiv illust.
///
/// Parsed once at the repository boundary; widgets never touch raw JSON.
class IllustUser {
  const IllustUser({
    required this.id,
    required this.name,
    required this.account,
    required this.profileImageUrl,
  });

  final int id;
  final String name;
  final String account;
  final String? profileImageUrl;

  /// Serializes back to the API shape so [IllustEntity.fromJson] round-trips
  /// (watch-later payload, feed snapshots).
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'account': account,
    'profile_image_urls': {'medium': profileImageUrl},
  };
}

/// The three pixiv size tiers that share one aspect ratio. `squareMedium`
/// is deliberately excluded: it is a square crop, not a resize, so it can
/// never substitute for another tier.
enum IllustImageTier { medium, large, original }

class IllustImageUrls {
  const IllustImageUrls({
    required this.squareMedium,
    required this.medium,
    required this.large,
    this.original,
    this.width,
    this.height,
  });

  final String squareMedium;
  final String medium;
  final String large;
  final String? original;

  /// Per-page dimensions (API `meta_pages[].width/height`). `null` when the
  /// feed payload omits them; the detail page falls back to the work-level
  /// [IllustEntity.width]/[IllustEntity.height] then.
  final int? width;
  final int? height;

  IllustImageUrls copyWith({int? width, int? height}) => IllustImageUrls(
    squareMedium: squareMedium,
    medium: medium,
    large: large,
    original: original,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  Map<String, dynamic> toJson() => {
    'square_medium': squareMedium,
    'medium': medium,
    'large': large,
    'original': original,
  };
}

class IllustTag {
  const IllustTag({required this.name, this.translatedName});

  final String name;
  final String? translatedName;

  Map<String, dynamic> toJson() => {
    'name': name,
    'translated_name': translatedName,
  };
}

enum IllustType { illust, manga, ugoira }

class IllustEntity {
  const IllustEntity({
    required this.id,
    required this.title,
    required this.type,
    required this.imageUrls,
    required this.caption,
    required this.user,
    required this.tags,
    required this.pageCount,
    required this.width,
    required this.height,
    required this.xRestrict,
    required this.aiType,
    required this.isBookmarked,
    required this.totalView,
    required this.totalBookmarks,
    this.captionVisible = true,
    this.metaPages = const [],
    this.metaSinglePageOriginalUrl,
    this.visible = true,
    this.createDate,
  });

  final int id;
  final String title;
  final IllustType type;
  final IllustImageUrls imageUrls;
  final String caption;
  final IllustUser user;
  final List<IllustTag> tags;
  final int pageCount;
  final int width;
  final int height;

  /// 0 = all ages, 1 = R-18 (x_restrict).
  final int xRestrict;
  final int aiType;
  final bool isBookmarked;
  final int totalView;
  final int totalBookmarks;

  final bool captionVisible;

  /// Per-page image URL sets for multi-page works (detail API payload).
  final List<IllustImageUrls> metaPages;

  /// `meta_single_page.original_image_url` for single-page works.
  final String? metaSinglePageOriginalUrl;

  /// false = deleted or restricted work (detail API).
  final bool visible;

  /// `create_date` raw ISO string (display uses y/m/d per beta56).
  final String? createDate;

  bool get isR18 => xRestrict == 1;

  bool get isAi => aiType == 2;

  bool get isUgoira => type == IllustType.ugoira;

  /// Feed/detail transition image. The caller owns the quality setting (D4),
  /// and passing this exact URL to the detail route keeps both Hero
  /// endpoints on the same cache key.
  String previewUrl(PreviewQuality quality) => switch (quality) {
    // Feed payloads never carry an original URL (list API limitation), so
    // the preview choices are medium and large only.
    PreviewQuality.medium => imageUrls.medium,
    PreviewQuality.large => imageUrls.large,
  };

  /// The width/height of one page. Multi-page works have per-page
  /// dimensions from the detail API (`meta_pages[].width/height`), which
  /// legitimately differ page to page; falling back to the work-level sizes
  /// keeps single-page and list payloads working.
  int pageWidthAt(int pageIndex) {
    if (pageCount > 1 && pageIndex >= 0 && pageIndex < metaPages.length) {
      final pageWidth = metaPages[pageIndex].width;
      if (pageWidth != null && pageWidth > 0) return pageWidth;
    }
    return width;
  }

  int pageHeightAt(int pageIndex) {
    if (pageCount > 1 && pageIndex >= 0 && pageIndex < metaPages.length) {
      final pageHeight = metaPages[pageIndex].height;
      if (pageHeight != null && pageHeight > 0) return pageHeight;
    }
    return height;
  }

  /// Seeds per-page dimensions from `/ajax/illust/{id}/pages` — the only
  /// endpoint carrying true per-page sizes (the app API's `meta_pages`
  /// ships `image_urls` alone). Slots missing from [dims] or carrying
  /// non-positive values keep the work-level fallback.
  IllustEntity withPageDimensions(List<({int width, int height})> dims) {
    if (dims.isEmpty || metaPages.isEmpty) return this;
    var changed = false;
    final pages = List<IllustImageUrls>.of(metaPages);
    for (var i = 0; i < pages.length && i < dims.length; i++) {
      final w = dims[i].width;
      final h = dims[i].height;
      if (w <= 0 || h <= 0) continue;
      pages[i] = pages[i].copyWith(width: w, height: h);
      changed = true;
    }
    return changed ? copyWith(metaPages: pages) : this;
  }

  /// Aspect ratio of one page, defaulting to the work-level ratio.
  double pageAspectRatioAt(int pageIndex) {
    final pageWidth = pageWidthAt(pageIndex);
    final pageHeight = pageHeightAt(pageIndex);
    if (pageWidth > 0 && pageHeight > 0) {
      return pageWidth / pageHeight;
    }
    return 1.0;
  }

  /// Original-size URL for [pageIndex] (downloads; beta56 downloader input).
  String? originalUrlAt(int pageIndex) {
    if (pageCount > 1) {
      if (pageIndex < 0 || pageIndex >= metaPages.length) return null;
      return metaPages[pageIndex].original ?? metaPages[pageIndex].large;
    }
    if (pageIndex != 0) return null;
    return metaSinglePageOriginalUrl ?? imageUrls.original ?? imageUrls.large;
  }

  /// Viewer URLs for [quality] (D4): original when available, else large.
  List<String> viewerUrls(ViewQuality quality) {
    if (pageCount > 1) {
      return [
        for (final page in metaPages)
          switch (quality) {
            ViewQuality.medium => page.large,
            ViewQuality.large => page.large,
            ViewQuality.original => page.original ?? page.large,
          },
      ];
    }
    return [
      switch (quality) {
        ViewQuality.medium => imageUrls.large,
        ViewQuality.large => imageUrls.large,
        ViewQuality.original =>
          metaSinglePageOriginalUrl ?? imageUrls.original ?? imageUrls.large,
      },
    ];
  }

  /// Detail-page main image URL for one page (三档之详情档). The feed
  /// snapshot has no original URLs, so this is only meaningful after the
  /// detail API payload is merged into the entity.
  String detailUrlAt(int pageIndex, DetailQuality quality) {
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.index(pageIndex, pageCount);
    }
    if (pageCount > 1) {
      if (pageIndex >= metaPages.length) return imageUrls.large;
      return switch (quality) {
        DetailQuality.medium ||
        DetailQuality.large => metaPages[pageIndex].large,
        DetailQuality.original =>
          metaPages[pageIndex].original ?? metaPages[pageIndex].large,
      };
    }
    return switch (quality) {
      DetailQuality.medium || DetailQuality.large => imageUrls.large,
      DetailQuality.original =>
        metaSinglePageOriginalUrl ?? imageUrls.original ?? imageUrls.large,
    };
  }

  /// Per-(work,page) key for [IllustTierCache]-style registries.
  String imageTierKeyAt(int pageIndex) => '${id}_$pageIndex';

  /// Which tier [url] represents on this work, or null when the URL is not
  /// one of this work's known image URLs (e.g. squareMedium crops).
  IllustImageTier? imageTierOf(String url) {
    if (url == imageUrls.medium) return IllustImageTier.medium;
    if (url == imageUrls.large) return IllustImageTier.large;
    if (url == metaSinglePageOriginalUrl || url == imageUrls.original) {
      return IllustImageTier.original;
    }
    for (final page in metaPages) {
      if (url == page.original) return IllustImageTier.original;
      if (url == page.large) return IllustImageTier.large;
      if (url == page.medium) return IllustImageTier.medium;
    }
    return null;
  }

  /// Quality-aware single-page viewer URL with original-first fallback.
  String viewerUrlAt(int pageIndex, ViewQuality quality) {
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.index(pageIndex, pageCount);
    }
    if (pageCount > 1) {
      if (pageIndex >= metaPages.length) {
        return imageUrls.large;
      }
      final page = metaPages[pageIndex];
      return switch (quality) {
        ViewQuality.medium => page.large,
        ViewQuality.large => page.large,
        ViewQuality.original => page.original ?? page.large,
      };
    }
    if (pageIndex != 0) {
      return imageUrls.large;
    }
    return switch (quality) {
      ViewQuality.medium => imageUrls.large,
      ViewQuality.large => imageUrls.large,
      ViewQuality.original =>
        metaSinglePageOriginalUrl ?? imageUrls.original ?? imageUrls.large,
    };
  }

  IllustEntity copyWith({
    bool? isBookmarked,
    Object? caption = _sentinel,
    Object? tags = _sentinel,
    Object? metaPages = _sentinel,
    Object? metaSinglePageOriginalUrl = _sentinel,
    bool? visible,
    int? pageCount,
    Object? createDate = _sentinel,
  }) {
    return IllustEntity(
      id: id,
      title: title,
      type: type,
      imageUrls: imageUrls,
      user: user,
      caption: identical(caption, _sentinel) ? this.caption : caption as String,
      tags: identical(tags, _sentinel) ? this.tags : tags as List<IllustTag>,
      pageCount: pageCount ?? this.pageCount,
      width: width,
      height: height,
      xRestrict: xRestrict,
      aiType: aiType,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      totalView: totalView,
      totalBookmarks: totalBookmarks,
      captionVisible: captionVisible,
      metaPages: identical(metaPages, _sentinel)
          ? this.metaPages
          : metaPages as List<IllustImageUrls>,
      metaSinglePageOriginalUrl: identical(metaSinglePageOriginalUrl, _sentinel)
          ? this.metaSinglePageOriginalUrl
          : metaSinglePageOriginalUrl as String?,
      visible: visible ?? this.visible,
      // U2 (R7): createDate was the constructor's last field and the only
      // one copyWith did not forward. Every store merge (mergeAll,
      // updateBookmark) goes through copyWith, so the detail response
      // silently dropped the date on every known entity.
      createDate: identical(createDate, _sentinel)
          ? this.createDate
          : createDate as String?,
    );
  }

  static const _sentinel = Object();

  /// Serializes to the API field shape; [IllustEntity.fromJson] accepts the
  /// output unchanged. Used for local persistence payloads (watch-later
  /// records, feed snapshots) — not a network wire format.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type.name,
    'image_urls': imageUrls.toJson(),
    'caption': caption,
    'user': user.toJson(),
    'tags': [for (final tag in tags) tag.toJson()],
    'page_count': pageCount,
    'width': width,
    'height': height,
    'x_restrict': xRestrict,
    'illust_ai_type': aiType,
    'is_bookmarked': isBookmarked,
    'total_view': totalView,
    'total_bookmarks': totalBookmarks,
    'meta_pages': [
      for (final page in metaPages)
        {
          'image_urls': page.toJson(),
          'width': page.width,
          'height': page.height,
        },
    ],
    'meta_single_page': {'original_image_url': metaSinglePageOriginalUrl},
    'visible': visible,
    'create_date': createDate,
  };

  /// Parses one illust object. Unknown/optional fields degrade gracefully;
  /// structural violations (missing id/title/user/urls) throw
  /// [FormatException] which the repository maps to [ApiParseError].
  factory IllustEntity.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final userJson = json['user'];
    final imageUrlsJson = json['image_urls'];
    if (id is! int ||
        title is! String ||
        userJson is! Map<String, dynamic> ||
        imageUrlsJson is! Map<String, dynamic>) {
      throw const FormatException('illust object is missing required fields');
    }
    final user = IllustUser(
      id: userJson['id'] is int
          ? userJson['id'] as int
          : int.tryParse('${userJson['id']}') ??
                (throw const FormatException('user id is invalid')),
      name: userJson['name'] is String ? userJson['name'] as String : '',
      account: userJson['account'] is String
          ? userJson['account'] as String
          : '',
      profileImageUrl: readOptionalString(
        (userJson['profile_image_urls'] as Map<String, dynamic>?)?['medium'],
      ),
    );
    String requiredUrl(String key) {
      final value = imageUrlsJson[key];
      if (value is! String) {
        throw FormatException('image_urls.$key is missing');
      }
      return value;
    }

    final tagsJson = json['tags'];
    final tags = <IllustTag>[
      if (tagsJson is List)
        for (final tag in tagsJson)
          if (tag is Map<String, dynamic> && tag['name'] is String)
            IllustTag(
              name: tag['name'] as String,
              translatedName: readOptionalString(tag['translated_name']),
            ),
    ];
    final typeValue = switch (json['type']) {
      'manga' => IllustType.manga,
      'ugoira' => IllustType.ugoira,
      _ => IllustType.illust,
    };
    return IllustEntity(
      id: id,
      title: title,
      type: typeValue,
      imageUrls: IllustImageUrls(
        squareMedium: requiredUrl('square_medium'),
        medium: requiredUrl('medium'),
        large: requiredUrl('large'),
        original: readOptionalString(imageUrlsJson['original']),
      ),
      caption: readOptionalString(json['caption']) ?? '',
      user: user,
      tags: tags,
      pageCount: json['page_count'] is int ? json['page_count'] as int : 1,
      width: json['width'] is int ? json['width'] as int : 0,
      height: json['height'] is int ? json['height'] as int : 0,
      xRestrict: json['x_restrict'] is int ? json['x_restrict'] as int : 0,
      aiType: json['illust_ai_type'] is int ? json['illust_ai_type'] as int : 0,
      isBookmarked: json['is_bookmarked'] == true,
      totalView: json['total_view'] is int ? json['total_view'] as int : 0,
      totalBookmarks: json['total_bookmarks'] is int
          ? json['total_bookmarks'] as int
          : 0,
      metaPages: [
        if (json['meta_pages'] is List)
          for (final page in json['meta_pages'] as List)
            if (page is Map<String, dynamic> &&
                page['image_urls'] is Map<String, dynamic>)
              _parseImageUrls(
                page['image_urls'] as Map<String, dynamic>,
                width: page['width'] is int ? page['width'] as int : null,
                height: page['height'] is int ? page['height'] as int : null,
              ),
      ],
      metaSinglePageOriginalUrl: readOptionalString(
        (json['meta_single_page']
            as Map<String, dynamic>?)?['original_image_url'],
      ),
      visible: json['visible'] is! bool || (json['visible'] as bool),
      createDate: readOptionalString(json['create_date']),
    );
  }

  /// Parses the page envelope `{illusts: [...], next_url: ...}`.
  static ({List<IllustEntity> illusts, String? nextUrl}) parsePage(
    Map<String, dynamic> json,
  ) {
    final illustsJson = json['illusts'];
    if (illustsJson is! List) {
      throw const FormatException('illusts list is missing');
    }
    final illusts = <IllustEntity>[];
    for (final item in illustsJson) {
      if (item is Map<String, dynamic>) {
        // Single malformed item is skipped observably via error surface at
        // the caller: structural errors bubble as FormatException.
        illusts.add(IllustEntity.fromJson(item));
      } else {
        throw const FormatException('illusts contains a non-object entry');
      }
    }
    final nextUrl = json['next_url'];
    return (
      illusts: illusts,
      nextUrl: nextUrl is String && nextUrl.isNotEmpty ? nextUrl : null,
    );
  }

  static IllustImageUrls _parseImageUrls(
    Map<String, dynamic> json, {
    int? width,
    int? height,
  }) {
    String requiredUrl(String key) {
      final value = json[key];
      if (value is! String) {
        throw FormatException('image_urls.$key is missing');
      }
      return value;
    }

    return IllustImageUrls(
      squareMedium: requiredUrl('square_medium'),
      medium: requiredUrl('medium'),
      large: requiredUrl('large'),
      original: readOptionalString(json['original']),
      width: width,
      height: height,
    );
  }

  @override
  String toString() =>
      'IllustEntity(${jsonEncode({'id': id, 'title': title})})';
}
