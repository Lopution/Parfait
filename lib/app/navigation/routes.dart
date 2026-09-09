import 'package:flutter/material.dart';

import '../../core/entity/comment_entity.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/search/search_models.dart';
import '../../features/comments/comments_page.dart';
import '../../features/home/recommended/recommended_home_page.dart';
import '../../features/new/new_page.dart';
import '../../features/ranking/ranking_page.dart';

import '../../features/settings/settings_page.dart';
import '../../features/history/history_page.dart';
import '../../features/illust/detail/illust_detail_page.dart';
import '../../features/home/home_page.dart';
import '../../features/login/login_page.dart';
import '../../features/onboarding/welcome_page.dart';
import '../../features/novel/novel_page.dart';
import '../../features/profile/profile_edit_page.dart';
import '../../features/profile/user_page.dart';
import '../../features/search/reverse_image_search_page.dart';
import '../../features/search/search_page.dart';
import '../../features/search/search_result_page.dart';
import '../../features/search/tag_search_page.dart';
import '../motion/replica_page_route.dart';
import '../widgets/app_snack_bar.dart';
import '../../l10n/context.dart';

/// Root tabs of the home shell. The shell (app layer) must not import feature
/// pages directly, so the tab list lives here next to the navigation facade.
const homeShellTabs = <Widget>[
  RecommendedHomePage(),
  RankingPage(),
  NewPage(),
  SearchHomePage(),
  SettingsPage(),
];

/// Navigation facade — the only file in the app allowed to import feature
/// pages from more than one feature (layering_test whitelists this one
/// cycle). All feature-to-feature navigation goes through these functions,
/// which take ids/parameters instead of widget instances so child F can
/// re-implement the facade with go_router paths without touching callers.
Future<void> openIllust(
  BuildContext context,
  int illustId, {
  IllustEntity? initialEntity,
  String heroScope = 'feed',
  String? heroImageUrl,
}) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => IllustDetailPage(
        illustId: illustId,
        initialEntity: initialEntity,
        heroScope: heroScope,
        heroImageUrl: heroImageUrl,
      ),
    ),
  );
}

Future<void> openUser(BuildContext context, int userId) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => UserPage(userId: userId)),
  );
}

Future<void> openNovel(BuildContext context, int novelId) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => NovelPage(novelId: novelId)),
  );
}

Future<void> openSearchInput(BuildContext context, {String initialKeyword = ''}) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => SearchInputPage(initialKeyword: initialKeyword),
    ),
  );
}

Future<void> openSearchResults(BuildContext context, SearchQuery query) {
  final keyword = query.keyword.trim();
  if (keyword.isEmpty) {
    showAppSnackBar(context, context.l10n.searchInputEmpty,);
    return Future<void>.value();
  }
  final id = _positiveNumericId(keyword);
  if (id != null) {
    switch (query.type) {
      case SearchResultType.illust:
        return openIllust(context, id);
      case SearchResultType.novel:
        return openNovel(context, id);
      case SearchResultType.user:
        return openUser(context, id);
    }
  }
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => SearchResultPage(query: query)),
  );
}

int? _positiveNumericId(String value) {
  if (!RegExp(r'^\d+$').hasMatch(value)) return null;
  final parsed = int.tryParse(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

Future<void> openReverseImageSearch(
  BuildContext context, {
  ReverseImageInputReference? initialReference,
}) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => ReverseImageSearchPage(
        initialReference: initialReference,
      ),
    ),
  );
}

Future<void> openIllustComments(BuildContext context, int illustId) {
  if (illustId <= 0) return Future<void>.value();
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => IllustCommentsPage(illustId: illustId),
    ),
  );
}

Future<void> openCommentReplies(BuildContext context, CommentEntity rootComment) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => CommentRepliesPage(rootComment: rootComment),
    ),
  );
}

Future<void> openHistory(BuildContext context) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => const HistoryPage()),
  );
}

Future<void> openLogin(
  BuildContext context, {
  bool isFirst = false,
  bool returnToHomeOnSuccess = false,
}) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => LoginPage(
        isFirst: isFirst,
        returnToHomeOnSuccess: returnToHomeOnSuccess,
      ),
    ),
  );
}

Future<void> openProfileEdit(BuildContext context, int userId) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => ProfileEditPage(userId: userId),
    ),
  );
}

Future<void> openTagSearch(BuildContext context, String keyword) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => TagSearchPage(keyword: keyword),
    ),
  );
}

/// Startup gate destinations (C4b): the gate itself lives in lib/app/ and
/// cannot import feature pages directly, so it resolves them here.
Widget startupGateWelcomePage() => const WelcomePage();

Widget startupGateLoginPage() => const LoginPage(returnToHomeOnSuccess: true);

Widget startupGateHomePage() => const HomePage();
