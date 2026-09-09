import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/account_store.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
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
import '../motion/motion_tokens.dart';
import '../widgets/app_snack_bar.dart';

class IllustRouteExtra {
  const IllustRouteExtra({
    this.entity,
    this.heroScope = 'feed',
    this.heroImageUrl,
  });

  final IllustEntity? entity;
  final String heroScope;
  final String? heroImageUrl;
}

class ImageViewerRouteExtra {
  const ImageViewerRouteExtra({required this.urls, this.entity});

  final List<String> urls;
  final IllustEntity? entity;
}

class _ImageViewerRoute extends ConsumerWidget {
  const _ImageViewerRoute({
    required this.illustId,
    required this.page,
    required this.quality,
    this.extra,
  });

  final int illustId;
  final int page;
  final ViewQuality quality;
  final ImageViewerRouteExtra? extra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity =
        extra?.entity ?? ref.watch(illustStoreProvider).get(illustId);
    final urls = extra?.urls ?? entity?.viewerUrls(quality) ?? const <String>[];
    return ImageViewerPage(urls: urls, initialPage: page);
  }
}

Widget _scoped(RouteObserver<ModalRoute<dynamic>> observer, Widget child) =>
    RouteObserverScope(observer: observer, child: child);

Page<dynamic> _page(
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget child,
) => CustomTransitionPage<dynamic>(
  key: state.pageKey,
  child: _scoped(observer, child),
  transitionDuration: MotionTokens.pageTransition,
  reverseTransitionDuration: MotionTokens.pageTransition,
  transitionsBuilder: (context, animation, secondaryAnimation, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionTokens.pageCurve,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  },
);

int _pathId(GoRouterState state, String name) =>
    int.parse(state.pathParameters[name]!);

SearchResultType _searchType(String? raw) => SearchResultType.values.firstWhere(
  (value) => value.name == raw,
  orElse: () => SearchResultType.illust,
);

T _searchEnum<T>(
  Iterable<T> values,
  String? raw,
  String Function(T value) wireValue,
  T fallback,
) => values.firstWhere(
  (value) => wireValue(value) == raw,
  orElse: () => fallback,
);

DateTime? _searchDate(String? raw) =>
    raw == null ? null : DateTime.tryParse(raw);

SearchFilters _searchFilters(GoRouterState state) => SearchFilters(
  target: _searchEnum(
    SearchTarget.values,
    state.uri.queryParameters['target'],
    (value) => value.wireValue,
    SearchTarget.partialMatchForTags,
  ),
  sort: _searchEnum(
    SearchSort.values,
    state.uri.queryParameters['sort'],
    (value) => value.wireValue,
    SearchSort.dateDesc,
  ),
  duration: _searchDuration(state.uri.queryParameters['duration']),
  startDate: _searchDate(state.uri.queryParameters['start']),
  endDate: _searchDate(state.uri.queryParameters['end']),
);

SearchQuery _searchQuery(GoRouterState state) {
  final keyword = state.uri.queryParameters['q'] ?? '';
  final filters = _searchFilters(state);
  return switch (_searchType(state.uri.queryParameters['type'])) {
    SearchResultType.illust => IllustSearchQuery(
      keyword: keyword,
      filters: filters,
    ),
    SearchResultType.novel => NovelSearchQuery(
      keyword: keyword,
      filters: filters,
    ),
    SearchResultType.user => UserSearchQuery(keyword: keyword),
  };
}

Map<String, String> _searchQueryParameters(SearchQuery query) {
  final filters = switch (query) {
    IllustSearchQuery(:final filters) => filters,
    NovelSearchQuery(:final filters) => filters,
    UserSearchQuery() => null,
  };
  return {
    'q': query.keyword,
    'type': query.type.name,
    if (filters != null) ...{
      'target': filters.target.wireValue,
      'sort': filters.sort.wireValue,
      if (filters.duration != null) 'duration': filters.duration!.wireValue,
      if (filters.startDate != null)
        'start': _searchDateText(filters.startDate!),
      if (filters.endDate != null) 'end': _searchDateText(filters.endDate!),
    },
  };
}

String _searchDateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

SearchDuration? _searchDuration(String? raw) {
  for (final value in SearchDuration.values) {
    if (value.wireValue == raw) return value;
  }
  return null;
}

List<RouteBase> _commonBranchRoutes(
  RouteObserver<ModalRoute<dynamic>> branchObserver, {
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
}) => [
  GoRoute(
    path: 'illust/:illustId',
    pageBuilder: (context, state) {
      final extra = state.extra;
      final initialEntity = extra is IllustRouteExtra
          ? extra.entity
          : extra is IllustEntity
          ? extra
          : null;
      return _page(
        state,
        branchObserver,
        IllustDetailPage(
          illustId: _pathId(state, 'illustId'),
          initialEntity: initialEntity,
          heroScope: extra is IllustRouteExtra ? extra.heroScope : 'feed',
          heroImageUrl: extra is IllustRouteExtra ? extra.heroImageUrl : null,
        ),
      );
    },
    routes: [
      GoRoute(
        path: 'viewer/:page',
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final quality = ViewQuality.fromCode(
            state.uri.queryParameters['quality'],
          );
          final extra = state.extra is ImageViewerRouteExtra
              ? state.extra! as ImageViewerRouteExtra
              : null;
          return _page(
            state,
            rootObserver,
            _ImageViewerRoute(
              illustId: _pathId(state, 'illustId'),
              page: int.parse(state.pathParameters['page']!),
              quality: quality,
              extra: extra,
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
          CommentRepliesPage(
            illustId: _pathId(state, 'illustId'),
            rootCommentId: _pathId(state, 'rootCommentId'),
            rootComment: state.extra is CommentEntity
                ? state.extra! as CommentEntity
                : null,
          ),
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
  bool includeHistory = true,
  List<RouteBase> routes = const [],
}) {
  final commonRoutes = _commonBranchRoutes(
    observer,
    rootNavigatorKey: rootNavigatorKey,
    rootObserver: rootObserver,
  );
  if (!includeHistory) {
    commonRoutes.removeWhere(
      (route) => route is GoRoute && route.path == 'history',
    );
  }
  return StatefulShellBranch(
    navigatorKey: navigatorKey,
    observers: [observer],
    restorationScopeId: restorationScopeId,
    preload: false,
    routes: [
      GoRoute(
        path: path,
        pageBuilder: (context, state) => _page(state, observer, home),
        routes: [...commonRoutes, ...routes],
      ),
    ],
  );
}

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
            includeHistory: false,
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
                routes: [
                  GoRoute(
                    path: 'view',
                    pageBuilder: (context, state) => _page(
                      state,
                      settingsRouteObserver,
                      const HistoryPage(),
                    ),
                  ),
                ],
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
/// pages from more than one feature. Callers pass ids and typed query objects;
/// durable navigation state is encoded in go_router paths and queries.
const _homeBranchRoots = <String>[
  '/recommended',
  '/ranking',
  '/new',
  '/search',
  '/settings',
];

String _currentBranch(BuildContext context) {
  final path = GoRouter.of(context).state.uri.path;
  return _homeBranchRoots.firstWhere(
    (root) => path == root || path.startsWith('$root/'),
    orElse: () => '/recommended',
  );
}

Future<void> _push(
  BuildContext context,
  String location, {
  Object? extra,
}) async {
  await context.push<void>(location, extra: extra);
}

Future<void> openIllust(
  BuildContext context,
  int illustId, {
  IllustEntity? initialEntity,
  String heroScope = 'feed',
  String? heroImageUrl,
}) async {
  await _push(
    context,
    '${_currentBranch(context)}/illust/$illustId',
    extra: IllustRouteExtra(
      entity: initialEntity,
      heroScope: heroScope,
      heroImageUrl: heroImageUrl,
    ),
  );
}

Future<void> openUser(BuildContext context, int userId) async {
  await _push(context, '${_currentBranch(context)}/user/$userId');
}

Future<void> openMe(BuildContext context) async {
  await _push(context, '${_currentBranch(context)}/me');
}

Future<void> openNovel(BuildContext context, int novelId) async {
  await _push(context, '${_currentBranch(context)}/novel/$novelId');
}

Future<void> openSearchInput(
  BuildContext context, {
  String initialKeyword = '',
}) async {
  final location = Uri(
    path: '/search/input',
    queryParameters: {'q': initialKeyword},
  ).toString();
  await _push(context, location);
}

Future<void> openSearchResults(BuildContext context, SearchQuery query) async {
  final keyword = query.keyword.trim();
  if (keyword.isEmpty) {
    showAppSnackBar(context, context.l10n.searchInputEmpty);
    return;
  }
  final id = _positiveNumericId(keyword);
  if (id != null) {
    switch (query.type) {
      case SearchResultType.illust:
        await openIllust(context, id);
      case SearchResultType.novel:
        await openNovel(context, id);
      case SearchResultType.user:
        await openUser(context, id);
    }
    return;
  }
  final location = Uri(
    path: '/search/results',
    queryParameters: _searchQueryParameters(query),
  ).toString();
  await _push(context, location);
}

void replaceSearchResults(BuildContext context, SearchQuery query) {
  final keyword = query.keyword.trim();
  if (keyword.isEmpty) {
    showAppSnackBar(context, context.l10n.searchInputEmpty);
    return;
  }
  final location = Uri(
    path: '/search/results',
    queryParameters: _searchQueryParameters(query),
  ).toString();
  context.replace(location);
}

int? _positiveNumericId(String value) {
  if (!RegExp(r'^\d+$').hasMatch(value)) return null;
  final parsed = int.tryParse(value);
  return parsed != null && parsed > 0 ? parsed : null;
}

Future<void> openReverseImageSearch(
  BuildContext context, {
  ReverseImageInputReference? initialReference,
}) async {
  await _push(context, '/reverse-image', extra: initialReference);
}

Future<void> openImageViewer(
  BuildContext context, {
  required IllustEntity entity,
  required int page,
  required ViewQuality quality,
}) async {
  await _push(
    context,
    '${_currentBranch(context)}/illust/${entity.id}/viewer/$page'
    '?quality=${quality.code}',
    extra: ImageViewerRouteExtra(
      urls: entity.viewerUrls(quality),
      entity: entity,
    ),
  );
}

Future<void> openIllustComments(BuildContext context, int illustId) async {
  if (illustId <= 0) return;
  await _push(context, '${_currentBranch(context)}/illust/$illustId/comments');
}

Future<void> openCommentReplies(
  BuildContext context,
  CommentEntity rootComment,
) async {
  await _push(
    context,
    '${_currentBranch(context)}/illust/${rootComment.illustId}'
    '/comments/${rootComment.id}',
    extra: rootComment,
  );
}

Future<void> openHistory(BuildContext context) async {
  await _push(context, '/settings/history/view');
}

Future<void> openLogin(
  BuildContext context, {
  bool isFirst = false,
  bool returnToHomeOnSuccess = false,
}) async {
  final queryParameters = <String, String>{
    if (isFirst) 'first': 'true',
    if (returnToHomeOnSuccess) 'return': 'true',
  };
  final location = Uri(
    path: '/login',
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  ).toString();
  await _push(context, location);
}

Future<void> openProfileEdit(BuildContext context, int userId) async {
  await _push(context, '${_currentBranch(context)}/profile/$userId/edit');
}

Future<void> openTagSearch(BuildContext context, String keyword) async {
  await _push(context, '/search/tag/${Uri.encodeComponent(keyword)}');
}
