import 'dart:convert';

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
}

class IllustImageUrls {
  const IllustImageUrls({
    required this.squareMedium,
    required this.medium,
    required this.large,
    this.original,
  });

  final String squareMedium;
  final String medium;
  final String large;
  final String? original;
}

class IllustTag {
  const IllustTag({required this.name, this.translatedName});

  final String name;
  final String? translatedName;
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

  bool get isR18 => xRestrict == 1;

  bool get isAi => aiType == 2;

  bool get isUgoira => type == IllustType.ugoira;

  IllustEntity copyWith({bool? isBookmarked}) {
    return IllustEntity(
      id: id,
      title: title,
      type: type,
      imageUrls: imageUrls,
      caption: caption,
      user: user,
      tags: tags,
      pageCount: pageCount,
      width: width,
      height: height,
      xRestrict: xRestrict,
      aiType: aiType,
      isBookmarked: isBookmarked ?? this.isBookmarked,
      totalView: totalView,
      totalBookmarks: totalBookmarks,
      captionVisible: captionVisible,
    );
  }

  /// Parses one illust object. Unknown/optional fields degrade gracefully;
  /// structural violations (missing id/title/user/urls) throw
  /// [FormatException] which the repository maps to [ApiParseError].
  factory IllustEntity.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final userJson = json['user'];
    final imageUrlsJson = json['image_urls'];
    if (id is! int || title is! String || userJson is! Map<String, dynamic> || imageUrlsJson is! Map<String, dynamic>) {
      throw const FormatException('illust object is missing required fields');
    }
    final user = IllustUser(
      id: userJson['id'] is int
          ? userJson['id'] as int
          : int.tryParse('${userJson['id']}') ?? (throw const FormatException('user id is invalid')),
      name: userJson['name'] is String ? userJson['name'] as String : '',
      account: userJson['account'] is String ? userJson['account'] as String : '',
      profileImageUrl: _optionalString(
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
              translatedName: _optionalString(tag['translated_name']),
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
        original: _optionalString(imageUrlsJson['original']),
      ),
      caption: _optionalString(json['caption']) ?? '',
      user: user,
      tags: tags,
      pageCount: json['page_count'] is int ? json['page_count'] as int : 1,
      width: json['width'] is int ? json['width'] as int : 0,
      height: json['height'] is int ? json['height'] as int : 0,
      xRestrict: json['x_restrict'] is int ? json['x_restrict'] as int : 0,
      aiType: json['illust_ai_type'] is int ? json['illust_ai_type'] as int : 0,
      isBookmarked: json['is_bookmarked'] == true,
      totalView: json['total_view'] is int ? json['total_view'] as int : 0,
      totalBookmarks:
          json['total_bookmarks'] is int ? json['total_bookmarks'] as int : 0,
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

  static String? _optionalString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  @override
  String toString() => 'IllustEntity(${jsonEncode({'id': id, 'title': title})})';
}
