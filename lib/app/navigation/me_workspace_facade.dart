import 'package:flutter/widgets.dart';

import '../../core/bookmark/bookmark_models.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_repository.dart';
import '../../features/profile/profile_filter_bar.dart';
import '../../features/profile/profile_illust_feed.dart';
import '../../features/profile/profile_novel_feed.dart';
import '../../features/profile/profile_user_feed.dart';

export '../../features/history/history_page.dart' show HistoryPage;
export '../../features/localnovel/local_novels_page.dart' show LocalNovelsPage;
export '../../features/novel/novel_markers_page.dart' show NovelMarkersPage;
export '../../features/watchlater/watchlater_page.dart' show WatchLaterPage;
export '../../features/watchlist/watchlist_page.dart' show WatchlistPage;

/// Cross-feature builders embedded inside `MeDashboardPage`'s wide workspace,
/// isolated from `routes.dart` and `route_facade.dart` so ordinary callers of
/// navigation helpers never pull feature pages into their compile unit.
Widget profileFilterBar({
  BookmarkEntityType? kind,
  ValueChanged<BookmarkEntityType>? onKindChanged,
  required UserRestrict restrict,
  required ValueChanged<UserRestrict> onRestrictChanged,
  String? tag,
  ValueChanged<String?>? onTagChanged,
}) => ProfileFilterBar(
  kind: kind,
  onKindChanged: onKindChanged,
  restrict: restrict,
  onRestrictChanged: onRestrictChanged,
  tag: tag,
  onTagChanged: onTagChanged,
);

Widget profileIllustFeed(ProfileFeedKey feedKey) =>
    ProfileIllustFeed(feedKey: feedKey, isNested: false);

Widget profileNovelFeed(ProfileFeedKey feedKey) =>
    ProfileNovelFeed(feedKey: feedKey, isNested: false);

Widget profileUserFeed(ProfileFeedKey feedKey) =>
    ProfileUserFeed(feedKey: feedKey, isNested: false);
