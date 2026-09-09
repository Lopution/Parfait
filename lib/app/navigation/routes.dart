import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/account_store.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/search/search_models.dart';
import '../../core/settings/app_settings.dart';
import '../../features/comments/comments_page.dart';
import '../../features/history/history_page.dart';
import '../../features/home/home_page.dart';
import '../../features/home/recommended/recommended_home_page.dart';
import '../../features/illust/detail/illust_detail_page.dart';
import '../../features/illust/viewer/image_viewer_page.dart';
import '../../features/login/login_page.dart';
import '../../features/login/login_webview_page.dart';
import '../../features/new/new_page.dart';
import '../../features/novel/novel_page.dart';
import '../../features/onboarding/language_page.dart';
import '../../features/onboarding/theme_page.dart';
import '../../features/onboarding/welcome_page.dart';
import '../../features/profile/profile_edit_page.dart';
import '../../features/profile/user_page.dart';
import '../../features/ranking/ranking_page.dart';
import '../../features/search/reverse_image_search_page.dart';
import '../../features/search/search_page.dart';
import '../../features/search/search_result_page.dart';
import '../../features/search/tag_search_page.dart';
import '../../features/settings/network_probe_page.dart';
import '../../features/settings/network_settings_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/settings/pages/translation_credentials_page.dart';
import '../../l10n/context.dart';
import '../motion/replica_page_route.dart';
import '../widgets/app_snack_bar.dart';

Widget _scoped(RouteObserver<ModalRoute<dynamic>> observer, Widget child) =>
    RouteObserverScope(observer: observer, child: child);

Page<dynamic> _page(
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget child,
) => MaterialPage<dynamic>(key: state.pageKey, child: _scoped(observer, child));

int _pathId(GoRouterState state, String name) =>
    int.parse(state.pathParameters[name]!);

SearchResultType _searchType(String? raw) => SearchResultType.values.firstWhere(
  (value) => value.name == raw,
  orElse: () => SearchResultType.illust,
);

SearchQuery _searchQuery(GoRouterState state) {
  final keyword = state.uri.queryParameters['q'] ?? '';
  return switch (_searchType(state.uri.queryParameters['type'])) {
    SearchResultType.illust => IllustSearchQuery(keyword: keyword),
    SearchResultType.novel => NovelSearchQuery(keyword: keyword),
    SearchResultType.user => UserSearchQuery(keyword: keyword),
  };
}

List<RouteBase> _commonBranchRoutes(
  RouteObserver<ModalRoute<dynamic>> branchObserver, {
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
}) => [
  GoRoute(
    path: 'illust/:illustId',
    pageBuilder: (context, state) {
      final initialEntity = state.extra is IllustEntity
          ? state.extra! as IllustEntity
          : null;
      return _page(
        state,
        branchObserver,
        IllustDetailPage(
          illustId: _pathId(state, 'illustId'),
          initialEntity: initialEntity,
        ),
      );
    },
    routes: [
      GoRoute(
        path: 'viewer/:page',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final entity = state.extra is IllustEntity
              ? state.extra! as IllustEntity
              : null;
          final quality = ViewQuality.fromCode(
            state.uri.queryParameters['quality'],
          );
          final urls = state.extra is List<String>
              ? state.extra! as List<String>
              : entity?.viewerUrls(quality) ?? const <String>[];
          return _page(
            state,
            rootObserver,
            ImageViewerPage(
              urls: urls,
              initialPage: int.parse(state.pathParameters['page']!),
            ),
          );
        },
      ),
      GoRoute(
        path: 'comments',
        pageBuilder: (context, state) => _page(
          state,
          branchObserver,
          IllustCommentsPage(illustId: _pathId(state, 'illustId')),
        ),
      ),
      GoRoute(
        path: 'comments/:rootCommentId',
        pageBuilder: (context, state) => _page(
          state,
          branchObserver,
          CommentRepliesPage(rootComment: state.extra! as CommentEntity),
        ),
      ),
    ],
  ),
  GoRoute(
    path: 'user/:userId',
    pageBuilder: (context, state) => _page(
      state,
      branchObserver,
      UserPage(userId: _pathId(state, 'userId')),
    ),
  ),
  GoRoute(
    path: 'me',
    pageBuilder: (context, state) =>
        _page(state, branchObserver, const MePage()),
  ),
  GoRoute(
    path: 'profile/:userId/edit',
    pageBuilder: (context, state) => _page(
      state,
      branchObserver,
      ProfileEditPage(userId: _pathId(state, 'userId')),
    ),
  ),
  GoRoute(
    path: 'novel/:novelId',
    pageBuilder: (context, state) => _page(
      state,
      branchObserver,
      NovelPage(novelId: _pathId(state, 'novelId')),
    ),
  ),
  GoRoute(
    path: 'history',
    pageBuilder: (context, state) =>
        _page(state, branchObserver, const HistoryPage()),
  ),
];

StatefulShellBranch _branch({
  required String path,
  required Widget home,
  required GlobalKey<NavigatorState> navigatorKey,
  required RouteObserver<ModalRoute<dynamic>> observer,
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
  required String restorationScopeId,
  List<RouteBase> routes = const [],
}) => StatefulShellBranch(
  navigatorKey: navigatorKey,
  observers: [observer],
  restorationScopeId: restorationScopeId,
  preload: false,
  routes: [
    GoRoute(
      path: path,
      pageBuilder: (context, state) => _page(state, observer, home),
      routes: [
        ..._commonBranchRoutes(
          observer,
          rootNavigatorKey: rootNavigatorKey,
          rootObserver: rootObserver,
        ),
        ...routes,
      ],
    ),
  ],
);

GoRouter createPixivRouter({
  AndroidIntentSource? intentSource,
  String initialLocation = '/welcome',
}) {
  final appRootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
  final recommendedNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'recommended',
  );
  final rankingNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ranking');
  final newNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'new');
  final searchNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'search');
  final settingsNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'settings',
  );

  final appRootRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final recommendedRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final rankingRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final newRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final searchRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final settingsRouteObserver = RouteObserver<ModalRoute<dynamic>>();

  return GoRouter(
    navigatorKey: appRootNavigatorKey,
    observers: [appRootRouteObserver],
    restorationScopeId: 'router',
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/recommended'),
      GoRoute(
        path: '/welcome',
        pageBuilder: (context, state) =>
            _page(state, appRootRouteObserver, const WelcomePage()),
        routes: [
          GoRoute(
            path: 'language',
            pageBuilder: (context, state) =>
                _page(state, appRootRouteObserver, const LanguagePage()),
          ),
          GoRoute(
            path: 'theme',
            pageBuilder: (context, state) =>
                _page(state, appRootRouteObserver, const ThemePage()),
          ),
        ],
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => _page(
          state,
          appRootRouteObserver,
          LoginPage(
            isFirst: state.uri.queryParameters['first'] == 'true',
            returnToHomeOnSuccess:
                state.uri.queryParameters['return'] == 'true',
          ),
        ),
        routes: [
          GoRoute(
            path: 'web',
            pageBuilder: (context, state) => _page(
              state,
              appRootRouteObserver,
              LoginWebViewPage(
                oauthService: ProviderScope.containerOf(
                  context,
                ).read(oauthServiceProvider),
                create: state.uri.queryParameters['create'] == 'true',
              ),
            ),
          ),
          GoRoute(
            path: 'callback',
            pageBuilder: (context, state) => _page(
              state,
              appRootRouteObserver,
              const LoginPage(returnToHomeOnSuccess: true),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/reverse-image',
        pageBuilder: (context, state) => _page(
          state,
          appRootRouteObserver,
          ReverseImageSearchPage(
            initialReference: state.extra is ReverseImageInputReference
                ? state.extra! as ReverseImageInputReference
                : null,
          ),
        ),
      ),
      StatefulShellRoute.indexedStack(
        restorationScopeId: 'home-shell',
        branches: [
          _branch(
            path: '/recommended',
            home: const RecommendedHomePage(),
            navigatorKey: recommendedNavigatorKey,
            observer: recommendedRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'recommended',
          ),
          _branch(
            path: '/ranking',
            home: const RankingPage(),
            navigatorKey: rankingNavigatorKey,
            observer: rankingRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'ranking',
          ),
          _branch(
            path: '/new',
            home: const NewPage(),
            navigatorKey: newNavigatorKey,
            observer: newRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'new',
          ),
          _branch(
            path: '/search',
            home: const SearchHomePage(),
            navigatorKey: searchNavigatorKey,
            observer: searchRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'search',
            routes: [
              GoRoute(
                path: 'input',
                pageBuilder: (context, state) => _page(
                  state,
                  searchRouteObserver,
                  SearchInputPage(
                    initialKeyword: state.uri.queryParameters['q'] ?? '',
                  ),
                ),
              ),
              GoRoute(
                path: 'results',
                pageBuilder: (context, state) => _page(
                  state,
                  searchRouteObserver,
                  SearchResultPage(query: _searchQuery(state)),
                ),
              ),
              GoRoute(
                path: 'tag/:keyword',
                pageBuilder: (context, state) => _page(
                  state,
                  searchRouteObserver,
                  TagSearchPage(keyword: state.pathParameters['keyword']!),
                ),
              ),
            ],
          ),
          _branch(
            path: '/settings',
            home: const SettingsPage(),
            navigatorKey: settingsNavigatorKey,
            observer: settingsRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'settings',
            routes: [
              GoRoute(
                path: 'account',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const AccountSettingsPage(),
                ),
              ),
              GoRoute(
                path: 'theme',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const ThemeSettingsPage(),
                ),
              ),
              GoRoute(
                path: 'language',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const LanguageSettingsPage(),
                ),
              ),
              GoRoute(
                path: 'translate',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const TranslateSettingsPage(),
                ),
                routes: [
                  GoRoute(
                    path: 'credentials/:provider',
                    pageBuilder: (context, state) => _page(
                      state,
                      settingsRouteObserver,
                      TranslationCredentialsPage(
                        baidu: state.pathParameters['provider'] == 'baidu',
                      ),
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 'network',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const NetworkSettingsPage(),
                ),
                routes: [
                  GoRoute(
                    path: 'probe',
                    pageBuilder: (context, state) => _page(
                      state,
                      settingsRouteObserver,
                      const NetworkProbePage(),
                    ),
                  ),
                  GoRoute(
                    path: 'advanced',
                    pageBuilder: (context, state) => _page(
                      state,
                      settingsRouteObserver,
                      const NetworkAdvancedSettingsPage(),
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 'browse',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const BrowseSettingsPage(),
                ),
              ),
              GoRoute(
                path: 'download',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const DownloadSettingsPage(),
                ),
                routes: [
                  GoRoute(
                    path: 'destination',
                    pageBuilder: (context, state) => _page(
                      state,
                      settingsRouteObserver,
                      const DownloadDestinationPage(),
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: 'history',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const HistorySettingsPage(),
                ),
              ),
              GoRoute(
                path: 'blocked',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const BlockedTagsPage(),
                ),
              ),
              GoRoute(
                path: 'tasks',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const DownloadTasksPage(),
                ),
              ),
              GoRoute(
                path: 'about',
                pageBuilder: (context, state) => _page(
                  state,
                  settingsRouteObserver,
                  const AboutSettingsPage(),
                ),
                routes: [
                  GoRoute(
                    path: 'licenses',
                    pageBuilder: (context, state) => _page(
                      state,
                      settingsRouteObserver,
                      const LicensePage(
                        applicationName: 'Pixiv Func',
                        applicationVersion: '0.1.0+1',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
        builder: (context, state, navigationShell) => _scoped(
          appRootRouteObserver,
          HomePage(
            navigationShell: navigationShell,
            intentSource: intentSource,
          ),
        ),
      ),
    ],
  );
}

/// Navigation facade — the only file in the app allowed to import feature
/// pages from more than one feature. F3c converts these paths to go_router
/// calls while callers continue to pass ids and typed query objects.
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

Future<void> openMe(BuildContext context, {VoidCallback? onEditProfile}) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => MePage(onEditProfile: onEditProfile),
    ),
  );
}

Future<void> openNovel(BuildContext context, int novelId) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => NovelPage(novelId: novelId)),
  );
}

Future<void> openSearchInput(
  BuildContext context, {
  String initialKeyword = '',
}) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => SearchInputPage(initialKeyword: initialKeyword),
    ),
  );
}

Future<void> openSearchResults(BuildContext context, SearchQuery query) {
  final keyword = query.keyword.trim();
  if (keyword.isEmpty) {
    showAppSnackBar(context, context.l10n.searchInputEmpty);
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
      builder: (_) =>
          ReverseImageSearchPage(initialReference: initialReference),
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

Future<void> openCommentReplies(
  BuildContext context,
  CommentEntity rootComment,
) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => CommentRepliesPage(rootComment: rootComment),
    ),
  );
}

Future<void> openHistory(BuildContext context) {
  return Navigator.of(
    context,
  ).push<void>(ReplicaPageRoute<void>(builder: (_) => const HistoryPage()));
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
    ReplicaPageRoute<void>(builder: (_) => ProfileEditPage(userId: userId)),
  );
}

Future<void> openTagSearch(BuildContext context, String keyword) {
  return Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => TagSearchPage(keyword: keyword)),
  );
}
