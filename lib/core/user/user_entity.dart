import 'dart:convert';

/// Non-secret, account-scoped user data shared by profile and relationship
/// surfaces.
///
/// The Pixiv API returns a small user object in previews and a richer user +
/// profile envelope from `/v1/user/detail`. Both shapes are normalized here so
/// pages never keep their own copies of profile state.
class UserEntity {
  const UserEntity({
    required this.id,
    required this.name,
    required this.account,
    this.profileImageUrl,
    this.backgroundImageUrl,
    this.comment,
    this.webpage,
    this.twitterUrl,
    this.pawooUrl,
    this.isFollowed,
    this.totalFollowUsers = 0,
    this.totalMyPixivUsers = 0,
    this.totalIllusts = 0,
    this.totalManga = 0,
    this.totalNovels = 0,
    this.totalIllustBookmarksPublic = 0,
    this.totalIllustSeries = 0,
    this.totalNovelSeries = 0,
    this.visible = true,
    this.isMuted = false,
    this.hasDetail = false,
  });

  final int id;
  final String name;
  final String account;
  final String? profileImageUrl;
  final String? backgroundImageUrl;
  final String? comment;
  final String? webpage;
  final String? twitterUrl;
  final String? pawooUrl;

  /// Null means this payload did not contain relationship state. That is
  /// different from an explicit `false`, which must be allowed to clear a
  /// stale remote value.
  final bool? isFollowed;

  final int totalFollowUsers;
  final int totalMyPixivUsers;
  final int totalIllusts;
  final int totalManga;
  final int totalNovels;
  final int totalIllustBookmarksPublic;
  final int totalIllustSeries;
  final int totalNovelSeries;

  /// False is a deleted/restricted user response; the false value is sticky
  /// when profiles are merged so a later preview cannot make it visible.
  final bool visible;

  /// Preview endpoints may mark a user as muted. This is retained for future
  /// cards and is never used as a reason to silently drop a page.
  final bool isMuted;

  /// Detail responses contain the complete profile counters/links. Preview
  /// responses only contain identity and relationship fields.
  final bool hasDetail;

  factory UserEntity.fromUserJson(Map<String, dynamic> json) {
    final id = _positiveInt(json['id'], 'user.id');
    final name = _requiredString(json['name'], 'user.name');
    final account = _optionalString(json['account']) ?? '';
    final imageUrls = _map(json['profile_image_urls']);
    final visible =
        _boolFromKeys(json, const ['is_access_blocking_user', 'is_blocked']) !=
        true;
    return UserEntity(
      id: id,
      name: name,
      account: account,
      profileImageUrl: _firstString(imageUrls, const [
        'medium',
        'px_170x170',
        'px_50x50',
      ]),
      comment: _optionalString(json['comment']),
      isFollowed: _optionalBool(json['is_followed']),
      visible: visible,
      isMuted: _optionalBool(json['is_muted']) ?? false,
    );
  }

  /// Normalizes a `user_previews` item, retaining the preview's user and mute
  /// flag. Its nested illusts are intentionally parsed by the owning feed
  /// repository into [IllustEntity] rather than copied into this entity.
  factory UserEntity.fromPreviewJson(Map<String, dynamic> json) {
    final user = _map(json['user']);
    final parsed = UserEntity.fromUserJson(user);
    final muted = _optionalBool(json['is_muted']);
    return muted == null ? parsed : parsed.copyWith(isMuted: muted);
  }

  /// Normalizes the `/v1/user/detail` envelope.
  factory UserEntity.fromDetailJson(Map<String, dynamic> json) {
    final user = _map(json['user']);
    final profile = _map(json['profile']);
    final parsed = UserEntity.fromUserJson(user);
    return parsed.copyWith(
      backgroundImageUrl: _optionalString(profile['background_image_url']),
      webpage: _optionalString(profile['webpage']),
      twitterUrl: _optionalString(profile['twitter_url']),
      pawooUrl: _optionalString(profile['pawoo_url']),
      totalFollowUsers: _nonNegativeInt(
        profile['total_follow_users'],
        'profile.total_follow_users',
      ),
      totalMyPixivUsers: _nonNegativeInt(
        profile['total_mypixiv_users'],
        'profile.total_mypixiv_users',
      ),
      totalIllusts: _nonNegativeInt(
        profile['total_illusts'],
        'profile.total_illusts',
      ),
      totalManga: _nonNegativeInt(
        profile['total_manga'],
        'profile.total_manga',
      ),
      totalNovels: _nonNegativeInt(
        profile['total_novels'],
        'profile.total_novels',
      ),
      totalIllustBookmarksPublic: _nonNegativeInt(
        profile['total_illust_bookmarks_public'],
        'profile.total_illust_bookmarks_public',
      ),
      totalIllustSeries: _nonNegativeInt(
        profile['total_illust_series'],
        'profile.total_illust_series',
      ),
      totalNovelSeries: _nonNegativeInt(
        profile['total_novel_series'],
        'profile.total_novel_series',
      ),
      hasDetail: true,
    );
  }

  UserEntity copyWith({
    int? id,
    String? name,
    String? account,
    Object? profileImageUrl = _unset,
    Object? backgroundImageUrl = _unset,
    Object? comment = _unset,
    Object? webpage = _unset,
    Object? twitterUrl = _unset,
    Object? pawooUrl = _unset,
    Object? isFollowed = _unset,
    int? totalFollowUsers,
    int? totalMyPixivUsers,
    int? totalIllusts,
    int? totalManga,
    int? totalNovels,
    int? totalIllustBookmarksPublic,
    int? totalIllustSeries,
    int? totalNovelSeries,
    bool? visible,
    bool? isMuted,
    bool? hasDetail,
  }) {
    return UserEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      account: account ?? this.account,
      profileImageUrl: identical(profileImageUrl, _unset)
          ? this.profileImageUrl
          : profileImageUrl as String?,
      backgroundImageUrl: identical(backgroundImageUrl, _unset)
          ? this.backgroundImageUrl
          : backgroundImageUrl as String?,
      comment: identical(comment, _unset) ? this.comment : comment as String?,
      webpage: identical(webpage, _unset) ? this.webpage : webpage as String?,
      twitterUrl: identical(twitterUrl, _unset)
          ? this.twitterUrl
          : twitterUrl as String?,
      pawooUrl: identical(pawooUrl, _unset)
          ? this.pawooUrl
          : pawooUrl as String?,
      isFollowed: identical(isFollowed, _unset)
          ? this.isFollowed
          : isFollowed as bool?,
      totalFollowUsers: totalFollowUsers ?? this.totalFollowUsers,
      totalMyPixivUsers: totalMyPixivUsers ?? this.totalMyPixivUsers,
      totalIllusts: totalIllusts ?? this.totalIllusts,
      totalManga: totalManga ?? this.totalManga,
      totalNovels: totalNovels ?? this.totalNovels,
      totalIllustBookmarksPublic:
          totalIllustBookmarksPublic ?? this.totalIllustBookmarksPublic,
      totalIllustSeries: totalIllustSeries ?? this.totalIllustSeries,
      totalNovelSeries: totalNovelSeries ?? this.totalNovelSeries,
      visible: visible ?? this.visible,
      isMuted: isMuted ?? this.isMuted,
      hasDetail: hasDetail ?? this.hasDetail,
    );
  }

  /// Merges a newer preview/detail into the canonical entity.
  ///
  /// Detail data replaces detail counters even when they are zero. Preview
  /// data only enriches identity/relationship fields and cannot erase a
  /// loaded detail profile.
  UserEntity merge(UserEntity incoming) {
    final detail = incoming.hasDetail ? incoming : this;
    return UserEntity(
      id: id,
      name: incoming.name.isNotEmpty ? incoming.name : name,
      account: incoming.account.isNotEmpty ? incoming.account : account,
      profileImageUrl: incoming.profileImageUrl ?? profileImageUrl,
      backgroundImageUrl: incoming.hasDetail
          ? incoming.backgroundImageUrl
          : backgroundImageUrl,
      comment: incoming.comment ?? comment,
      webpage: detail.webpage,
      twitterUrl: detail.twitterUrl,
      pawooUrl: detail.pawooUrl,
      isFollowed: incoming.isFollowed ?? isFollowed,
      totalFollowUsers: detail.totalFollowUsers,
      totalMyPixivUsers: detail.totalMyPixivUsers,
      totalIllusts: detail.totalIllusts,
      totalManga: detail.totalManga,
      totalNovels: detail.totalNovels,
      totalIllustBookmarksPublic: detail.totalIllustBookmarksPublic,
      totalIllustSeries: detail.totalIllustSeries,
      totalNovelSeries: detail.totalNovelSeries,
      visible: visible && incoming.visible,
      isMuted: isMuted || incoming.isMuted,
      hasDetail: hasDetail || incoming.hasDetail,
    );
  }

  @override
  String toString() => 'UserEntity(${jsonEncode({'id': id, 'name': name})})';
}

const _unset = Object();

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('user payload object is missing');
}

int _positiveInt(Object? value, String field) {
  if (value is int && value > 0) return value;
  throw FormatException('$field must be a positive integer');
}

int _nonNegativeInt(Object? value, String field) {
  if (value is int && value >= 0) return value;
  throw FormatException('$field must be a non-negative integer');
}

String _requiredString(Object? value, String field) {
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$field must be a non-empty string');
}

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

bool? _optionalBool(Object? value) => value is bool ? value : null;

bool? _boolFromKeys(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _optionalBool(json[key]);
    if (value != null) return value;
  }
  return null;
}

String? _firstString(Map<String, dynamic>? json, List<String> keys) {
  if (json == null) return null;
  for (final key in keys) {
    final value = _optionalString(json[key]);
    if (value != null) return value;
  }
  return null;
}
