import 'package:flutter/foundation.dart';

import '../user/user_repository.dart';

enum ProfileFeedKind { work, bookmarks, following, fans, myPixiv }

/// UI selector for the profile work tab. Series is a display section backed
/// by its own feed (`/v1/user/illust-series`), deliberately decoupled from
/// the wire-level [UserWorkType] used by `/v1/user/illusts`.
enum ProfileWorkSection { illust, manga, novel, series }

extension ProfileWorkSectionWire on ProfileWorkSection {
  /// Wire `type` for sections served by `/v1/user/illusts`; series never
  /// reaches that endpoint so the fallback is irrelevant there.
  UserWorkType get wireWorkType => switch (this) {
    ProfileWorkSection.illust => UserWorkType.illust,
    ProfileWorkSection.manga => UserWorkType.manga,
    ProfileWorkSection.novel => UserWorkType.novel,
    ProfileWorkSection.series => UserWorkType.illust,
  };
}

/// Stable identity for one profile feed. It includes every selector that can
/// affect a request, so pagination and scroll positions never cross streams.
@immutable
class ProfileFeedKey {
  const ProfileFeedKey({
    required this.userId,
    required this.kind,
    this.workType = UserWorkType.illust,
    this.restrict = UserRestrict.public,
    this.bookmarkTag,
  });

  final int userId;
  final ProfileFeedKind kind;
  final UserWorkType workType;
  final UserRestrict restrict;

  /// Bookmark tag filter (`/v1/user/bookmarks/illust?tag=`); only meaningful
  /// for [ProfileFeedKind.bookmarks].
  final String? bookmarkTag;

  @override
  bool operator ==(Object other) =>
      other is ProfileFeedKey &&
      other.userId == userId &&
      other.kind == kind &&
      other.workType == workType &&
      other.restrict == restrict &&
      other.bookmarkTag == bookmarkTag;

  @override
  int get hashCode =>
      Object.hash(userId, kind, workType, restrict, bookmarkTag);

  @override
  String toString() =>
      'ProfileFeedKey(user:$userId, kind:${kind.name}, '
      'type:${workType.name}, restrict:${restrict.name}, '
      'tag:$bookmarkTag)';
}
