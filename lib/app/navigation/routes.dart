import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../haptics/app_haptics.dart';
import '../widgets/feed/feed_text_warmup.dart';
import '../../core/auth/account_store.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/debug/trace_marks.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/network/api_date.dart';
import '../../core/entity/illust_entity.dart';
import '../image_tier_cache.dart';
import '../../core/entity/illust_store.dart';
import '../../core/illust/illust_detail_controller.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/illust/ranking_repository.dart';
import '../../core/illust/recommended_repository.dart';
import '../../core/new/new_feed_models.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart' hide NovelPage;
import '../../core/novel/novel_store.dart';
import '../../core/platform/intent_router.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_shortcut.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/user/user_repository.dart';
import '../../features/bookmark/bookmark_tags_page.dart';
import '../../features/profile/bookmark_tag_feed_page.dart';
import '../../features/comments/comments_page.dart';
import '../../features/history/history_page.dart';
import '../../features/novel/local_novel_reader_page.dart';
import '../../features/localnovel/local_novels_page.dart';
import '../../features/watchlater/watchlater_page.dart';
import '../../features/novel/novel_markers_page.dart';
import '../../features/watchlist/watchlist_page.dart';
import '../../features/home/home_page.dart';
import '../../features/home/recommended/recommended_home_page.dart';
import '../../features/illust/detail/illust_detail_page.dart';
import '../../features/illust/detail/illust_detail_pager_page.dart';
import '../../features/illust/detail/widgets/detail_overlay_frame.dart';
import '../../features/illust/detail/widgets/info_block.dart';
import '../../features/illust/viewer/image_viewer_page.dart';
import '../../features/login/login_page.dart';
import '../../features/login/login_webview_page.dart';
import '../../features/new/new_page.dart';
import '../../features/novel/novel_page.dart';
import '../../features/novel/novel_series_page.dart';
import '../../features/onboarding/language_page.dart';
import '../../features/onboarding/user_agreement_page.dart';
import '../../features/onboarding/welcome_page.dart';
import '../../features/profile/profile_edit_page.dart';
import '../../features/profile/user_page.dart';
import '../../features/ranking/novel_ranking_page.dart';
import '../../features/ranking/ranking_page.dart';
import '../../features/search/docked_search.dart';
import '../../features/search/reverse_image_search_page.dart';
import '../../features/search/search_page.dart';
import '../../features/search/search_result_page.dart';
import '../../features/search/tag_search_page.dart';
import '../../features/series/illust_series_page.dart';
import '../../features/spotlight/spotlight_article_page.dart';
import '../../features/spotlight/spotlight_feed_page.dart';
import '../../features/settings/network_probe_page.dart';
import '../../features/settings/pages/frame_probe_page.dart';
import '../../features/settings/network_settings_page.dart';
import '../../features/settings/me_dashboard_page.dart';
import '../../features/settings/settings_catalog.dart' show focusQuery;
import '../../features/settings/settings_page.dart';
import '../widgets/settings/settings_anchor.dart';
import '../../features/settings/pages/translation_credentials_page.dart';
import '../../l10n/context.dart';
import '../motion/hero_transition.dart';
import '../motion/motion_tokens.dart';
import 'func_page.dart';
import '../pixiv_image.dart';
import '../startup_gate.dart';
import '../widgets/app_snack_bar.dart';
import '../layout/form_factor.dart';
import '../widgets/home_branch_stack.dart';
import '../widgets/feed/feed_grid.dart';
import '../widgets/feed/feed_states.dart' show FeedError;
import '../widgets/func_bottom_nav.dart';

part 'route_branches.dart';
part 'route_extras.dart';
part 'route_facade.dart';
part 'route_query_codecs.dart';
part 'route_search_facade.dart';

GoRouter createPixivRouter({String initialLocation = '/splash'}) {
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

  final appRootRouteObserver = ExitAwareRouteObserver();
  final recommendedRouteObserver = ExitAwareRouteObserver();
  final rankingRouteObserver = ExitAwareRouteObserver();
  final newRouteObserver = ExitAwareRouteObserver();
  final searchRouteObserver = ExitAwareRouteObserver();
  final settingsRouteObserver = ExitAwareRouteObserver();

  final router = GoRouter(
    navigatorKey: appRootNavigatorKey,
    observers: [appRootRouteObserver],
    restorationScopeId: 'router',
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, _) => homeStartDestination(
          ProviderScope.containerOf(
            context,
            listen: false,
          ).read(settingsProvider).value,
        ).rootPath,
      ),
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
              return _page(
                context,
                state,
                appRootRouteObserver,
                LoginWebViewPage(oauthService: oauth, create: create),
              );
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
      _overlayRoute(
        '/reverse-image',
        rootNavigatorKey: appRootNavigatorKey,
        rootObserver: appRootRouteObserver,
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
      ),
      // The personal profile is an app-level page, not a home tab. On a
      // phone /me renders over the home shell; beside a rail it opens in
      // the current branch instead (_appPageLocation). Common routes stay
      // mounted so the shared facade keeps working from inside profile
      // pages.
      _overlayRoute(
        '/me',
        rootNavigatorKey: appRootNavigatorKey,
        rootObserver: appRootRouteObserver,
        pageBuilder: (context, state) =>
            _page(context, state, appRootRouteObserver, _mePage(state)),
      ),
      _overlayRoute(
        '/downloads',
        rootNavigatorKey: appRootNavigatorKey,
        rootObserver: appRootRouteObserver,
        pageBuilder: (context, state) => _page(
          context,
          state,
          appRootRouteObserver,
          const DownloadTasksPage(),
        ),
      ),
      StatefulShellRoute(
        restorationScopeId: 'home-shell',
        // Branch Navigators stay mounted in place and fade through when the
        // selected home destination changes.
        navigatorContainerBuilder: (context, navigationShell, children) =>
            HomeBranchStack(shell: navigationShell, children: children),
        // The shell appears at once, and moves aside under a page pushed
        // over it like any page under a branch push (TRANS-01).
        pageBuilder: (context, state, navigationShell) => FuncPage<dynamic>(
          key: state.pageKey,
          restorationId: RestorationScope.maybeOf(context) == null
              ? null
              : 'home-shell-page',
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          child: _scoped(
            appRootRouteObserver,
            HomePage(navigationShell: navigationShell),
          ),
        ),
        branches: [
          _branch(
            path: '/recommended',
            branchIndex: 0,
            home: const RecommendedHomePage(),
            homeBuilder: (context, state) => RecommendedHomePage(
              initialType: _recommendedType(state.uri.queryParameters['type']),
              onTypeChanged: (type) => replaceRecommendedType(context, type),
            ),
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
              date: _rankingDate(state),
              onRouteChanged: (mode, date) =>
                  replaceRankingMode(context, mode, date),
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
            homeBuilder: (context, state) => NewPage(
              initialScope: _newFeedScope(state.uri.queryParameters['scope']),
              onScopeChanged: (scope) => replaceNewFeed(context, scope),
            ),
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
            includeSearch: false,
            routes: _searchRoutes(searchRouteObserver, prefix: ''),
          ),
          _branch(
            path: '/settings',
            branchIndex: 4,
            home: const MeDashboardPage(),
            navigatorKey: settingsNavigatorKey,
            observer: settingsRouteObserver,
            rootNavigatorKey: appRootNavigatorKey,
            rootObserver: appRootRouteObserver,
            restorationScopeId: 'settings',
            routes: _settingsSubRoutes(settingsRouteObserver),
          ),
        ],
      ),
    ],
  );
  if (TraceMarks.enabled) _markPages(router);
  return router;
}

/// Marks each page [router] shows in the system trace.
void _markPages(GoRouter router) {
  final delegate = router.routerDelegate;
  delegate.addListener(() {
    // The top match, not `uri`: a pushed route never shows in `uri`.
    final top = delegate.currentConfiguration.lastOrNull;
    if (top != null) TraceMarks.page(top.matchedLocation);
  });
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

/// Opens the download tasks screen from process-level triggers (tray menu).
void openDownloadsFromRouter(GoRouter router, {bool? rail}) {
  final path = _livePathOf(router);
  if (_isPreHomePath(path)) return;
  if (path == '/downloads' || path.endsWith('/downloads')) return;
  final effectiveRail = rail ?? _hasRailFromRouter(router);
  unawaited(
    router.push<void>(
      _appPageLocation(router, 'downloads', rail: effectiveRail),
    ),
  );
}

String _livePathOf(GoRouter router) {
  try {
    return router.state.uri.path;
  } on Object {
    final config = router.routerDelegate.currentConfiguration;
    if (config.isNotEmpty) return config.uri.path;
    return router.routeInformationProvider.value.uri.path;
  }
}

bool _isPreHomePath(String path) =>
    path == '/' ||
    path == '/splash' ||
    path == '/user-agreement' ||
    path == '/welcome' ||
    path.startsWith('/welcome/') ||
    path == '/login' ||
    path.startsWith('/login/');

bool _hasRailFromRouter(GoRouter router) {
  final navContext = router.routerDelegate.navigatorKey.currentContext;
  if (navContext == null) return false;
  return FormFactor.of(navContext).hasRail(MediaQuery.sizeOf(navContext).width);
}
