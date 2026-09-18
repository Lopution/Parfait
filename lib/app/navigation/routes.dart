import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/account_store.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/entity/illust_entity.dart';
import '../image_tier_cache.dart';
import '../../core/entity/illust_store.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/network/compat/network_providers.dart';
import '../../core/platform/intent_router.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/search/search_models.dart';
import '../../core/settings/app_settings.dart';
import '../../features/bookmark/bookmark_tags_page.dart';
import '../../features/profile/bookmark_tag_feed_page.dart';
import '../../features/comments/comments_page.dart';
import '../../features/history/history_page.dart';
import '../../features/novel/local_novel_reader_page.dart';
import '../../features/localnovel/local_novels_page.dart';
import '../../features/watchlater/watchlater_page.dart';
import '../../features/watchlist/watchlist_page.dart';
import '../../features/home/home_page.dart';
import '../../features/home/recommended/recommended_home_page.dart';
import '../../features/illust/detail/illust_detail_page.dart';
import '../../features/illust/viewer/image_viewer_page.dart';
import '../../features/login/login_page.dart';
import '../../features/login/login_webview_desktop_page.dart';
import '../../features/login/login_webview_page.dart';
import '../../features/new/new_page.dart';
import '../../features/novel/novel_page.dart';
import '../../features/onboarding/language_page.dart';
import '../../features/onboarding/theme_page.dart';
import '../../features/onboarding/user_agreement_page.dart';
import '../../features/onboarding/welcome_page.dart';
import '../../features/profile/profile_edit_page.dart';
import '../../features/profile/user_page.dart';
import '../../features/ranking/novel_ranking_page.dart';
import '../../features/ranking/ranking_page.dart';
import '../../features/search/reverse_image_search_page.dart';
import '../../features/search/search_page.dart';
import '../../features/search/search_result_page.dart';
import '../../features/search/tag_search_page.dart';
import '../../features/series/illust_series_page.dart';
import '../../features/spotlight/spotlight_article_page.dart';
import '../../features/spotlight/spotlight_feed_page.dart';
import '../../features/settings/network_probe_page.dart';
import '../../features/settings/network_settings_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/settings/pages/translation_credentials_page.dart';
import '../../l10n/context.dart';
import '../motion/hero_transition.dart';
import '../motion/motion_tokens.dart';
import '../motion/page_transitions.dart';
import '../pixiv_image.dart';
import '../startup_gate.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/func_bottom_nav.dart';

class IllustRouteExtra {
  const IllustRouteExtra({
    this.entity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
  });

  final IllustEntity? entity;
  final String heroScope;
  final String? heroImageUrl;

  /// Decode width of the feed card that produced [heroImageUrl]. The detail
  /// page decodes its hero-phase image at this width so the first frame is
  /// the same cache entry the feed already painted.
  final int? heroImageDecodeWidth;
}

class ImageViewerRouteExtra {
  const ImageViewerRouteExtra({
    required this.urls,
    this.entity,
    this.heroScope,
  });

  final List<String> urls;
  final IllustEntity? entity;
  final String? heroScope;
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
    // Prefer the store entity over the tap-time snapshot: when the detail
    // payload lands mid-session it carries original-tier URLs the snapshot
    // lacked, and recomputing urls lets PixivImage's gapless URL swap
    // upgrade to the real tier instead of staying on large forever.
    final entity =
        ref.watch(illustStoreProvider).get(illustId) ?? extra?.entity;
    final urls = entity?.viewerUrls(quality) ?? extra?.urls ?? const <String>[];
    return ImageViewerPage(
      urls: urls,
      initialPage: page,
      heroTagForPage: extra?.heroScope == null
          ? null
          : (page) {
              final base = illustHeroTag(extra!.heroScope!, illustId);
              return page == 0 ? base : '$base-$page';
            },
      tierKeyForPage: entity == null
          ? null
          : (page) => entity.imageTierKeyAt(page),
      tier: quality.tier,
      onPageChanged: (page) => replaceImageViewerPage(
        context,
        illustId: illustId,
        page: page,
        quality: quality,
        extra: extra,
      ),
    );
  }
}

Widget _scoped(RouteObserver<ModalRoute<dynamic>> observer, Widget child) =>
    RouteObserverScope(observer: observer, child: child);

Page<dynamic> _page(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget child,
) {
  // Reduced-motion collapses the slide without dropping the state it
  // communicates: the route still changes on the same frame.
  final duration = MotionTokens.resolve(context, MotionTokens.pageTransition);
  return CustomTransitionPage<dynamic>(
    key: state.pageKey,
    restorationId: RestorationScope.maybeOf(context) == null
        ? null
        : state.pageKey.value,
    // The detail route slides at the same time as the Hero overlay. Keeping
    // its static subtree in one repaint layer prevents the route animation
    // from repainting every image card on each tick; Hero still extracts its
    // own child into the navigator overlay and keeps the custom flight clip.
    child: _scoped(observer, child),
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FuncRouteTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    },
  );
}

/// Modal page variant of [_page]: keyboard-first surfaces (search input)
/// rise a short distance from the bottom edge with a fade instead of the
/// full trailing-edge slide.
Page<dynamic> _modalPage(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget child,
) {
  final duration = MotionTokens.resolve(context, MotionTokens.modalTransition);
  return CustomTransitionPage<dynamic>(
    key: state.pageKey,
    restorationId: RestorationScope.maybeOf(context) == null
        ? null
        : state.pageKey.value,
    child: _scoped(observer, child),
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FuncModalTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    },
  );
}

/// Applies the same transition freeze + raster snapshot as `_page`'s
/// builder, driven by the enclosing route's `secondaryAnimation`. The home
/// shell is a [NoTransitionPage], so root-level pushes/pops (settings,
/// viewer) over it would otherwise re-raster the whole shell — branch
/// feeds, bottom navigation and the active branch page — on every frame.
class _SecondaryAnimationTickerGate extends StatefulWidget {
  const _SecondaryAnimationTickerGate({required this.child});

  final Widget child;

  @override
  State<_SecondaryAnimationTickerGate> createState() =>
      _SecondaryAnimationTickerGateState();
}

class _SecondaryAnimationTickerGateState
    extends State<_SecondaryAnimationTickerGate> {
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _route?.secondaryAnimation?.removeStatusListener(_onStatus);
    _route = route;
    _route?.secondaryAnimation?.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _route?.secondaryAnimation?.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) => setState(() {});

  @override
  Widget build(BuildContext context) {
    final secondary = _route?.secondaryAnimation;
    return TickerMode(
      enabled: !(secondary?.isAnimating ?? false),
      child: RoutePopSnapshot(
        animation: _route?.animation ?? const AlwaysStoppedAnimation<double>(1),
        secondaryAnimation:
            secondary ?? const AlwaysStoppedAnimation<double>(0),
        child: widget.child,
      ),
    );
  }
}

int _pathId(GoRouterState state, String name) =>
    int.parse(state.pathParameters[name]!);

RankingMode _rankingMode(String? raw) => RankingMode.values.firstWhere(
  (mode) => mode.name == raw,
  orElse: () => RankingMode.day,
);

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
  bool includeHistory = true,
}) {
  final routes = <RouteBase>[
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
          context,
          state,
          branchObserver,
          IllustDetailPage(
            illustId: _pathId(state, 'illustId'),
            initialEntity: initialEntity,
            heroScope: extra is IllustRouteExtra ? extra.heroScope : 'feed',
            heroImageUrl: extra is IllustRouteExtra ? extra.heroImageUrl : null,
            heroImageDecodeWidth: extra is IllustRouteExtra
                ? extra.heroImageDecodeWidth
                : null,
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
              context,
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
            context,
            state,
            branchObserver,
            CommentsPage(workId: _pathId(state, 'illustId')),
          ),
        ),
        GoRoute(
          path: 'comments/:rootCommentId',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentRepliesPage(
              workId: _pathId(state, 'illustId'),
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
        context,
        state,
        branchObserver,
        UserPage(userId: _pathId(state, 'userId')),
      ),
    ),
    GoRoute(
      path: 'series/:seriesId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        IllustSeriesPage(seriesId: _pathId(state, 'seriesId')),
      ),
    ),
    GoRoute(
      path: 'spotlight',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const SpotlightFeedPage()),
    ),
    GoRoute(
      path: 'spotlight/article/:articleId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        SpotlightArticlePage(
          articleId: _pathId(state, 'articleId'),
          articleUrl: state.uri.queryParameters['url'],
        ),
      ),
    ),
    GoRoute(
      path: 'profile/:userId/edit',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        ProfileEditPage(userId: _pathId(state, 'userId')),
      ),
    ),
    GoRoute(
      path: 'novel/:novelId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NovelPage(novelId: _pathId(state, 'novelId')),
      ),
      routes: [
        GoRoute(
          path: 'comments',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentsPage(
              workId: _pathId(state, 'novelId'),
              kind: CommentWorkKind.novel,
            ),
          ),
        ),
        GoRoute(
          path: 'comments/:rootCommentId',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            CommentRepliesPage(
              workId: _pathId(state, 'novelId'),
              kind: CommentWorkKind.novel,
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
      path: 'novel-ranking',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const NovelRankingPage()),
    ),
    GoRoute(
      path: 'history',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const HistoryPage()),
    ),
    GoRoute(
      path: 'watchlater',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const WatchLaterPage()),
    ),
    GoRoute(
      path: 'watchlist',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const WatchlistPage()),
    ),
    GoRoute(
      path: 'local-novels',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const LocalNovelsPage()),
      routes: [
        GoRoute(
          path: ':localId',
          pageBuilder: (context, state) => _page(
            context,
            state,
            branchObserver,
            LocalNovelReaderPage(localId: _pathId(state, 'localId')),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'bookmarks/tags',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const BookmarkTagsPage()),
    ),
    GoRoute(
      path: 'bookmarks/tag',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        BookmarkTagFeedPage(
          tag: state.uri.queryParameters['tag'] ?? '',
          restrict: state.uri.queryParameters['restrict'] == 'private'
              ? BookmarkRestrict.private
              : BookmarkRestrict.public,
        ),
      ),
    ),
    // Tag search opens on top of whatever stack the tag was tapped in (detail
    // page, user page, reverse-image result). Routing it to the search branch
    // would switch tabs and lose the page the user came from.
    GoRoute(
      path: 'tag/:keyword',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        TagSearchPage(keyword: state.pathParameters['keyword']!),
      ),
    ),
  ];
  if (!includeHistory) {
    routes.removeWhere((route) => route is GoRoute && route.path == 'history');
  }
  return routes;
}

StatefulShellBranch _branch({
  required String path,
  required int branchIndex,
  required Widget home,
  Widget Function(BuildContext context, GoRouterState state)? homeBuilder,
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
    includeHistory: includeHistory,
  );
  return StatefulShellBranch(
    navigatorKey: navigatorKey,
    observers: [observer],
    restorationScopeId: restorationScopeId,
    preload: false,
    routes: [
      GoRoute(
        path: path,
        pageBuilder: (context, state) => _page(
          context,
          state,
          observer,
          // The bottom bar lives at this layer (inside the branch
          // navigator's root page), so a pushed secondary route covers it
          // naturally — no hide animation, full-height from frame one.
          BranchRootScaffold(
            branchIndex: branchIndex,
            child: homeBuilder?.call(context, state) ?? home,
          ),
        ),
        routes: [...commonRoutes, ...routes],
      ),
    ],
  );
}

GoRouter createPixivRouter({String initialLocation = '/splash'}) {
  final appRootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
  final recommendedNavigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'recommended',
  );
  final rankingNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ranking');
  final newNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'new');
  final searchNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'search');
  final meNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'me');

  final appRootRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final recommendedRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final rankingRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final newRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final searchRouteObserver = RouteObserver<ModalRoute<dynamic>>();
  final meRouteObserver = RouteObserver<ModalRoute<dynamic>>();

  return GoRouter(
    navigatorKey: appRootNavigatorKey,
    observers: [appRootRouteObserver],
    restorationScopeId: 'router',
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/recommended'),
      GoRoute(
        path: '/splash',
        pageBuilder: (context, state) =>
            _page(context, state, appRootRouteObserver, const SplashPage()),
      ),
      GoRoute(
        path: '/welcome',
        pageBuilder: (context, state) =>
            _page(context, state, appRootRouteObserver, const WelcomePage()),
        routes: [
          GoRoute(
            path: 'language',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const LanguagePage(),
            ),
          ),
          GoRoute(
            path: 'theme',
            pageBuilder: (context, state) =>
                _page(context, state, appRootRouteObserver, const ThemePage()),
          ),
        ],
      ),
      GoRoute(
        path: '/user-agreement',
        pageBuilder: (context, state) => _page(
          context,
          state,
          appRootRouteObserver,
          const UserAgreementPage(),
        ),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => _page(
          context,
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
            pageBuilder: (context, state) {
              final container = ProviderScope.containerOf(context);
              final oauth = container.read(oauthServiceProvider);
              final create = state.uri.queryParameters['create'] == 'true';
              // Desktop uses the InAppWebView (WebView2) implementation;
              // webview_flutter has no Windows backend.
              final page = container.read(platformCapsProvider).isDesktop
                  ? LoginWebViewDesktopPage(oauthService: oauth, create: create)
                  : LoginWebViewPage(oauthService: oauth, create: create);
              return _page(context, state, appRootRouteObserver, page);
            },
          ),
          GoRoute(
            path: 'callback',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              LoginPage(
                returnToHomeOnSuccess: true,
                callback: state.extra is AccountCallbackRoute
                    ? state.extra! as AccountCallbackRoute
                    : null,
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/reverse-image',
        pageBuilder: (context, state) => _page(
          context,
          state,
          appRootRouteObserver,
          ReverseImageSearchPage(
            initialReference: state.extra is ReverseImageInputReference
                ? state.extra! as ReverseImageInputReference
                : null,
          ),
        ),
        // Results open illust/user pages on top of the reverse-image page
        // itself (root stack). Pushing a shell location from here would stack
        // a second home shell on the root navigator.
        routes: _commonBranchRoutes(
          appRootRouteObserver,
          rootNavigatorKey: appRootNavigatorKey,
          rootObserver: appRootRouteObserver,
        ),
      ),
      // App settings are an app-level flow pushed on the root navigator, not
      // a personal-content tab: /settings and /settings/... render over the
      // home shell. Common routes stay mounted so the shared facade keeps
      // working from inside settings pages (no history duplication — history
      // already has /settings/history/view).
      GoRoute(
        path: '/settings',
        pageBuilder: (context, state) =>
            _page(context, state, appRootRouteObserver, const SettingsPage()),
        routes: [
          ..._commonBranchRoutes(
            appRootRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            includeHistory: false,
          ),
          GoRoute(
            path: 'account',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const AccountSettingsPage(),
            ),
          ),
          GoRoute(
            path: 'theme',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const ThemeSettingsPage(),
            ),
          ),
          GoRoute(
            path: 'language',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const LanguageSettingsPage(),
            ),
          ),
          GoRoute(
            path: 'translate',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const TranslateSettingsPage(),
            ),
            routes: [
              GoRoute(
                path: 'credentials/:provider',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  appRootRouteObserver,
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
              context,
              state,
              appRootRouteObserver,
              const NetworkSettingsPage(),
            ),
            routes: [
              GoRoute(
                path: 'probe',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  appRootRouteObserver,
                  const NetworkProbePage(),
                ),
              ),
              GoRoute(
                path: 'advanced',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  appRootRouteObserver,
                  const NetworkAdvancedSettingsPage(),
                ),
              ),
            ],
          ),
          GoRoute(
            path: 'browse',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const BrowseSettingsPage(),
            ),
          ),
          GoRoute(
            path: 'download',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const DownloadSettingsPage(),
            ),
            routes: [
              GoRoute(
                path: 'destination',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  appRootRouteObserver,
                  const DownloadDestinationPage(),
                ),
              ),
            ],
          ),
          GoRoute(
            path: 'history',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const HistorySettingsPage(),
            ),
            routes: [
              GoRoute(
                path: 'view',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  appRootRouteObserver,
                  const HistoryPage(),
                ),
              ),
            ],
          ),
          GoRoute(
            path: 'muted',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const MutedItemsPage(),
            ),
          ),
          GoRoute(
            path: 'backup',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const BackupSettingsPage(),
            ),
          ),
          GoRoute(
            path: 'tasks',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const DownloadTasksPage(),
            ),
          ),
          GoRoute(
            path: 'about',
            pageBuilder: (context, state) => _page(
              context,
              state,
              appRootRouteObserver,
              const AboutSettingsPage(),
            ),
            routes: [
              GoRoute(
                path: 'licenses',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  appRootRouteObserver,
                  const LicensePage(
                    applicationName: 'Pixiv Func',
                    applicationVersion: '0.1.0',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        restorationScopeId: 'home-shell',
        pageBuilder: (context, state, navigationShell) => NoTransitionPage(
          key: state.pageKey,
          restorationId: RestorationScope.maybeOf(context) == null
              ? null
              : 'home-shell-page',
          child: _scoped(
            appRootRouteObserver,
            _SecondaryAnimationTickerGate(
              child: HomePage(navigationShell: navigationShell),
            ),
          ),
        ),
        branches: [
          _branch(
            path: '/recommended',
            branchIndex: 0,
            home: const RecommendedHomePage(),
            navigatorKey: recommendedNavigatorKey,
            observer: recommendedRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'recommended',
          ),
          _branch(
            path: '/ranking',
            branchIndex: 1,
            home: const RankingPage(),
            homeBuilder: (context, state) => RankingPage(
              initialMode: _rankingMode(state.uri.queryParameters['mode']),
              onModeChanged: (mode) => replaceRankingMode(context, mode),
            ),
            navigatorKey: rankingNavigatorKey,
            observer: rankingRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'ranking',
          ),
          _branch(
            path: '/new',
            branchIndex: 2,
            home: const NewPage(),
            navigatorKey: newNavigatorKey,
            observer: newRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'new',
          ),
          _branch(
            path: '/search',
            branchIndex: 3,
            home: const SearchHomePage(),
            navigatorKey: searchNavigatorKey,
            observer: searchRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'search',
            routes: [
              GoRoute(
                path: 'input',
                pageBuilder: (context, state) => _modalPage(
                  context,
                  state,
                  searchRouteObserver,
                  SearchInputPage(
                    initialKeyword: state.uri.queryParameters['q'] ?? '',
                    initialType: _searchType(state.uri.queryParameters['type']),
                    onTypeChanged: (keyword, type) => replaceSearchInput(
                      context,
                      keyword: keyword,
                      type: type,
                    ),
                  ),
                ),
              ),
              GoRoute(
                path: 'results',
                pageBuilder: (context, state) => _page(
                  context,
                  state,
                  searchRouteObserver,
                  SearchResultPage(query: _searchQuery(state)),
                ),
              ),
            ],
          ),
          _branch(
            path: '/me',
            branchIndex: 4,
            home: const MePage(),
            navigatorKey: meNavigatorKey,
            observer: meRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'me',
          ),
        ],
      ),
    ],
  );
}

Future<void> routeExternalIntent(
  GoRouter router,
  AndroidIntentResult result,
) async {
  switch (result) {
    case SharedImageAndroidIntent(
      :final contentUri,
      :final mimeType,
      :final sizeBytes,
    ):
      await router.push<void>(
        '/reverse-image',
        extra: ReverseImageInputReference(
          contentUri: contentUri.toString(),
          mimeType: mimeType,
          sizeBytes: sizeBytes,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.androidSend,
        ),
      );
    case RoutedAndroidIntent(:final route):
      switch (route) {
        case IllustRoute(:final illustId):
          router.go('/recommended/illust/$illustId');
        case UserRoute(:final userId):
          router.go('/recommended/user/$userId');
        case AccountCallbackRoute():
          await router.push<void>('/login/callback', extra: route);
        case UnknownRoute():
        case ForeignUri():
          break;
      }
    case RejectedAndroidIntent():
    case IgnoredAndroidIntent():
      break;
  }
}

/// Navigation facade — the only file in the app allowed to import feature
/// pages from more than one feature. Callers pass ids and typed query objects;
/// durable navigation state is encoded in go_router paths and queries.
///
/// Every page that can host a detail/user/tag push has the common routes
/// mounted under it: the five home tabs and the root-level reverse-image and
/// settings pages. Pushes stay inside the stack the user is looking at.
const _stackRoots = <String>[
  '/recommended',
  '/ranking',
  '/new',
  '/search',
  '/me',
  '/settings',
  '/reverse-image',
];

String _currentStackRoot(BuildContext context) {
  final path = GoRouter.of(context).state.uri.path;
  return _stackRoots.firstWhere(
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
  int? heroImageDecodeWidth,
}) async {
  await _push(
    context,
    '${_currentStackRoot(context)}/illust/$illustId',
    extra: IllustRouteExtra(
      entity: initialEntity,
      heroScope: heroScope,
      heroImageUrl: heroImageUrl,
      heroImageDecodeWidth: heroImageDecodeWidth,
    ),
  );
}

Future<void> openUser(BuildContext context, int userId) async {
  await _push(context, '${_currentStackRoot(context)}/user/$userId');
}

Future<void> openIllustSeries(BuildContext context, int seriesId) async {
  await _push(context, '${_currentStackRoot(context)}/series/$seriesId');
}

Future<void> openSpotlight(BuildContext context) async {
  await _push(context, '${_currentStackRoot(context)}/spotlight');
}

Future<void> openSpotlightArticle(
  BuildContext context, {
  required int articleId,
  String? articleUrl,
}) async {
  final location = Uri(
    path: '${_currentStackRoot(context)}/spotlight/article/$articleId',
    queryParameters: {'url': ?articleUrl},
  ).toString();
  await _push(context, location);
}

Future<void> openMe(BuildContext context) async {
  // "我的" is a primary destination: opening it switches the shell branch
  // rather than pushing a page inside the current stack.
  context.go('/me');
}

/// App settings live on the root navigator, pushed over the shell so any
/// tab can reach them without owning a personal-content slot.
Future<void> openSettings(BuildContext context) async {
  await _push(context, '/settings');
}

Future<void> openNovel(BuildContext context, int novelId) async {
  await _push(context, '${_currentStackRoot(context)}/novel/$novelId');
}

Future<void> openNovelRanking(BuildContext context) async {
  await _push(context, '${_currentStackRoot(context)}/novel-ranking');
}

Future<void> openWatchLater(BuildContext context) async {
  await _push(context, '${_currentStackRoot(context)}/watchlater');
}

Future<void> openWatchlist(BuildContext context) async {
  await _push(context, '${_currentStackRoot(context)}/watchlist');
}

Future<void> openLocalNovels(BuildContext context) async {
  await _push(context, '${_currentStackRoot(context)}/local-novels');
}

Future<void> openLocalNovelReader(BuildContext context, int localId) async {
  await _push(context, '${_currentStackRoot(context)}/local-novels/$localId');
}

Future<void> openBookmarkTags(BuildContext context) async {
  await _push(context, '${_currentStackRoot(context)}/bookmarks/tags');
}

Future<void> openBookmarkTagFeed(
  BuildContext context, {
  required String tag,
  required BookmarkRestrict restrict,
}) async {
  final location = Uri(
    path: '${_currentStackRoot(context)}/bookmarks/tag',
    queryParameters: {'tag': tag, 'restrict': restrict.name},
  ).toString();
  await _push(context, location);
}

Future<void> openSearchInput(
  BuildContext context, {
  String initialKeyword = '',
  SearchResultType type = SearchResultType.illust,
}) async {
  final location = Uri(
    path: '/search/input',
    queryParameters: {'q': initialKeyword, 'type': type.name},
  ).toString();
  await _push(context, location);
}

void replaceSearchInput(
  BuildContext context, {
  required String keyword,
  required SearchResultType type,
}) {
  final location = Uri(
    path: '/search/input',
    queryParameters: {'q': keyword, 'type': type.name},
  ).toString();
  context.replace(location);
}

void replaceRankingMode(BuildContext context, RankingMode mode) {
  final location = Uri(
    path: '/ranking',
    queryParameters: {'mode': mode.name},
  ).toString();
  context.replace(location);
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
  String? heroScope,
}) async {
  // Warm the tapped page's viewer URL before the route mounts. precacheImage
  // shares the in-flight decode stream for the same provider key, so the
  // viewer's first frame lands on an already-resolving entry instead of a
  // cold placeholder — the flash seen when zooming while the detail page
  // was still loading. Runs uncapped like the viewer's own provider.
  unawaited(
    PixivImage.preload(
      context,
      entity.viewerUrlAt(page, quality),
      cacheManager: ProviderScope.containerOf(
        context,
        listen: false,
      ).read(pixivNetworkFactoryProvider).imageCacheManager,
      tierKey: entity.imageTierKeyAt(page),
      tier: quality.tier,
      // A context that unmounts mid-push (branch switch racing the tap)
      // makes the deferred precache throw — best-effort, so swallow.
    ).then((_) {}, onError: (_, _) {}),
  );
  await _push(
    context,
    '${_currentStackRoot(context)}/illust/${entity.id}/viewer/$page'
    '?quality=${quality.code}',
    extra: ImageViewerRouteExtra(
      urls: entity.viewerUrls(quality),
      entity: entity,
      heroScope: heroScope,
    ),
  );
}

void replaceImageViewerPage(
  BuildContext context, {
  required int illustId,
  required int page,
  required ViewQuality quality,
  ImageViewerRouteExtra? extra,
}) {
  context.replace(
    '${_currentStackRoot(context)}/illust/$illustId/viewer/$page'
    '?quality=${quality.code}',
    extra: extra,
  );
}

Future<void> openIllustComments(BuildContext context, int illustId) async {
  if (illustId <= 0) return;
  await _push(
    context,
    '${_currentStackRoot(context)}/illust/$illustId/comments',
  );
}

Future<void> openNovelComments(BuildContext context, int novelId) async {
  if (novelId <= 0) return;
  await _push(context, '${_currentStackRoot(context)}/novel/$novelId/comments');
}

Future<void> openCommentReplies(
  BuildContext context,
  CommentEntity rootComment,
) async {
  final workPath = switch (rootComment.kind) {
    CommentWorkKind.illust => 'illust',
    CommentWorkKind.novel => 'novel',
  };
  await _push(
    context,
    '${_currentStackRoot(context)}/$workPath/${rootComment.workId}'
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
  await _push(context, '${_currentStackRoot(context)}/profile/$userId/edit');
}

Future<void> openTagSearch(BuildContext context, String keyword) async {
  await _push(
    context,
    '${_currentStackRoot(context)}/tag/${Uri.encodeComponent(keyword)}',
  );
}
