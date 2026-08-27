import 'package:flutter/foundation.dart';

import '../../core/user/user_repository.dart';

/// Public tabs for a remote user profile.
enum ProfileTab { work, bookmarked, following, about }

/// Additional tabs shown on the current user's profile, in beta56 order.
enum MeProfileTab { bookmarked, following, fans, myPixiv, work }

enum ProfileFeedKind { work, bookmarks, following, fans, myPixiv }

/// Stable identity for one profile feed. It includes every selector that can
/// affect a request, so pagination and scroll positions never cross streams.
@immutable
class ProfileFeedKey {
  const ProfileFeedKey({
    required this.userId,
    required this.kind,
    this.workType = UserWorkType.illust,
    this.restrict = UserRestrict.public,
  });

  final int userId;
  final ProfileFeedKind kind;
  final UserWorkType workType;
  final UserRestrict restrict;

  @override
  bool operator ==(Object other) =>
      other is ProfileFeedKey &&
      other.userId == userId &&
      other.kind == kind &&
      other.workType == workType &&
      other.restrict == restrict;

  @override
  int get hashCode => Object.hash(userId, kind, workType, restrict);

  @override
  String toString() =>
      'ProfileFeedKey(user:$userId, kind:${kind.name}, '
      'type:${workType.name}, restrict:${restrict.name})';
}
