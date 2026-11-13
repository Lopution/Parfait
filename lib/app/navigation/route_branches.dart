part of 'routes.dart';

List<RouteBase> _searchRoutes(
  RouteObserver<ModalRoute<dynamic>> observer, {
  required String prefix,
}) {
  return [
    GoRoute(
      path: '${prefix}input',
      pageBuilder: (context, state) {
        // The docked panel narrowing hands over its session — the text as
        // typed and the filter drafts — as the location's extra (R10).
        final draft = state.extra;
        final carried = draft is _SearchInputDraft ? draft : null;
        return _page(
          context,
          state,
          observer,
          SearchInputPage(
            initialKeyword:
                carried?.keyword ?? state.uri.queryParameters['q'] ?? '',
            initialType:
                carried?.type ?? _searchType(state.uri.queryParameters['type']),
            initialIllustFilters: carried?.illustFilters,
            initialNovelFilters: carried?.novelFilters,
            onTypeChanged: (keyword, type) =>
                replaceSearchInput(context, keyword: keyword, type: type),
          ),
        );
      },
    ),
    GoRoute(
      path: '${prefix}results',
      pageBuilder: (context, state) => _page(
        context,
        state,
        observer,
        SearchResultPage(
          query: _searchQuery(state),
          onTypeChanged: (query) => replaceSearchResults(context, query),
        ),
      ),
    ),
  ];
}

List<RouteBase> _commonBranchRoutes(
  RouteObserver<ModalRoute<dynamic>> branchObserver, {
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
  bool includeSearch = true,
  bool includeAppPages = false,
}) {
  final routes = <RouteBase>[
    GoRoute(
      path: 'illust/:illustId',
      pageBuilder: (context, state) {
        final extra = state.extra;
        final illustId = _pathId(state, 'illustId');
        if (extra is IllustRouteExtra) {
          // A card inside a paged feed hands over the feed's work list:
          // the detail becomes a horizontal pager across it. Ids missing from the list — deep links, restored
          // routes — fall back to the single-work page.
          final source = extra.pagerSource;
          if (source != null && source.ids.contains(illustId)) {
            return _page(
              context,
              state,
              branchObserver,
              _RememberedIllust(
                builder: (_, remember) => IllustDetailPagerPage(
                  source: source,
                  initialIllustId: illustId,
                  heroScope: extra.heroScope,
                  heroImageUrl: extra.heroImageUrl,
                  heroImageDecodeWidth: extra.heroImageDecodeWidth,
                  onActiveChanged: remember,
                ),
              ),
              sharedElement: extra.heroImageUrl != null,
            );
          }
          return _page(
            context,
            state,
            branchObserver,
            _RememberedIllust(
              builder: (_, _) => IllustDetailPage(
                illustId: illustId,
                initialEntity: extra.entity,
                heroScope: extra.heroScope,
                heroImageUrl: extra.heroImageUrl,
                heroImageDecodeWidth: extra.heroImageDecodeWidth,
              ),
            ),
            sharedElement: extra.heroImageUrl != null,
          );
        }
        // A restored route has lost its extra, pager source included: it
        // opens the work the pager last settled on.
        return _page(
          context,
          state,
          branchObserver,
          _RememberedIllust(
            builder: (remembered, _) => IllustDetailPage(
              illustId: remembered ?? illustId,
              initialEntity: remembered == null && extra is IllustEntity
                  ? extra
                  : null,
            ),
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
              sharedElement: extra?.heroScope != null,
              // The dark stage covers the page below by itself.
              sharedElementBackdrop: false,
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
      path: 'novel-series/:seriesId',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NovelSeriesFeedPage(seriesId: _pathId(state, 'seriesId')),
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
        NovelPage(
          novelId: _pathId(state, 'novelId'),
          atPixivPage: switch (state.extra) {
            NovelRouteExtra(:final atPixivPage) => atPixivPage,
            _ => null,
          },
        ),
      ),
      routes: [
        GoRoute(
          path: 'image/:imageId',
          parentNavigatorKey: rootNavigatorKey,
          pageBuilder: (context, state) => _page(
            context,
            state,
            rootObserver,
            _NovelImageRoute(
              novelId: _pathId(state, 'novelId'),
              imageId: state.pathParameters['imageId']!,
            ),
          ),
        ),
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
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NovelRankingPage(
          initialMode: _novelRankingMode(state.uri.queryParameters['mode']),
          date: _rankingDate(state),
          onRouteChanged: (mode, date) =>
              replaceNovelRankingMode(context, mode, date),
        ),
      ),
    ),
    GoRoute(
      path: 'new-novels',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        NewPage(
          type: NewFeedType.novel,
          initialScope: _newFeedScope(state.uri.queryParameters['scope']),
          onScopeChanged: (scope) => replaceNewNovelScope(context, scope),
        ),
      ),
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
      path: 'novel-markers',
      pageBuilder: (context, state) =>
          _page(context, state, branchObserver, const NovelMarkersPage()),
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
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        BookmarkTagsPage(
          kind: _bookmarkKindFromQuery(state.uri.queryParameters['kind']),
          initialRestrict: _bookmarkRestrictFromQuery(
            state.uri.queryParameters['restrict'],
          ),
        ),
      ),
    ),
    GoRoute(
      path: 'bookmarks/tag',
      pageBuilder: (context, state) => _page(
        context,
        state,
        branchObserver,
        BookmarkTagFeedPage(
          tag: state.uri.queryParameters['tag'] ?? '',
          kind: _bookmarkKindFromQuery(state.uri.queryParameters['kind']),
          restrict: _bookmarkRestrictFromQuery(
            state.uri.queryParameters['restrict'],
          ),
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
  if (includeSearch) {
    routes.addAll(_searchRoutes(branchObserver, prefix: 'search/'));
  }
  if (includeAppPages) {
    // The app-level pages, opened inside a branch beside the rail
    // (_appPageLocation).
    routes.addAll([
      GoRoute(
        path: 'me',
        pageBuilder: (context, state) =>
            _page(context, state, branchObserver, _mePage(state)),
      ),
      GoRoute(
        path: 'downloads',
        pageBuilder: (context, state) =>
            _page(context, state, branchObserver, const DownloadTasksPage()),
      ),
    ]);
  }
  return routes;
}

MePage _mePage(GoRouterState state) => MePage(
  initialTab: MeTab.values.asNameMap()[state.uri.queryParameters['tab']],
);

GoRoute _overlayRoute(
  String path, {
  required GlobalKey<NavigatorState> rootNavigatorKey,
  required RouteObserver<ModalRoute<dynamic>> rootObserver,
  required GoRouterPageBuilder pageBuilder,
}) {
  return GoRoute(
    path: path,
    parentNavigatorKey: rootNavigatorKey,
    pageBuilder: pageBuilder,
    routes: _commonBranchRoutes(
      rootObserver,
      rootNavigatorKey: rootNavigatorKey,
      rootObserver: rootObserver,
    ),
  );
}

/// Settings subpages grafted under the `/settings` home branch. They take
/// the branch observer so route-aware widgets behave the same as on any
/// other branch stack.
List<RouteBase> _settingsSubRoutes(
  RouteObserver<ModalRoute<dynamic>> observer,
) {
  return [
    GoRoute(
      path: 'all',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const SettingsPage()),
    ),
    GoRoute(
      path: 'account',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const AccountSettingsPage()),
    ),
    GoRoute(
      path: 'theme',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const ThemeSettingsPage()),
    ),
    GoRoute(
      path: 'language',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const LanguageSettingsPage()),
    ),
    GoRoute(
      path: 'translate',
      pageBuilder: (context, state) => _settingsPage(
        context,
        state,
        observer,
        const TranslateSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'credentials/:provider',
          pageBuilder: (context, state) => _settingsPage(
            context,
            state,
            observer,
            TranslationCredentialsPage(
              baidu: state.pathParameters['provider'] == 'baidu',
            ),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'network',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const NetworkSettingsPage()),
      routes: [
        GoRoute(
          path: 'probe',
          pageBuilder: (context, state) =>
              _settingsPage(context, state, observer, const NetworkProbePage()),
        ),
        GoRoute(
          path: 'advanced',
          pageBuilder: (context, state) => _settingsPage(
            context,
            state,
            observer,
            const NetworkAdvancedSettingsPage(),
          ),
        ),
      ],
    ),
    // The route ships in every build so the release unlock gesture
    // (about page, 7 taps) can reach it — only the entry is hidden.
    GoRoute(
      path: 'frame-probe',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const FrameProbePage()),
    ),
    GoRoute(
      path: 'browse',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const BrowseSettingsPage()),
    ),
    GoRoute(
      path: 'motion',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const MotionSettingsPage()),
    ),
    GoRoute(
      path: 'navigation',
      pageBuilder: (context, state) => _settingsPage(
        context,
        state,
        observer,
        const NavigationSettingsPage(),
      ),
      routes: [
        GoRoute(
          path: 'bottom-bar',
          pageBuilder: (context, state) => _settingsPage(
            context,
            state,
            observer,
            const BottomBarSettingsPage(),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'download',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const DownloadSettingsPage()),
      routes: [
        GoRoute(
          path: 'destination',
          pageBuilder: (context, state) => _settingsPage(
            context,
            state,
            observer,
            const DownloadDestinationPage(),
          ),
        ),
      ],
    ),
    GoRoute(
      path: 'muted',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const MutedItemsPage()),
    ),
    GoRoute(
      path: 'backup',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const BackupSettingsPage()),
    ),
    GoRoute(
      path: 'tasks',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const DownloadTasksPage()),
    ),
    GoRoute(
      path: 'about',
      pageBuilder: (context, state) =>
          _settingsPage(context, state, observer, const AboutSettingsPage()),
      routes: [
        GoRoute(
          path: 'licenses',
          pageBuilder: (context, state) => _settingsPage(
            context,
            state,
            observer,
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) => LicensePage(
                applicationName: 'Parfait',
                applicationVersion: snapshot.data?.version,
              ),
            ),
          ),
        ),
      ],
    ),
  ];
}

/// A settings page that reveals the entry its `focus` query names (the
/// settings search links there).
Page<dynamic> _settingsPage(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget page,
) => _page(
  context,
  state,
  observer,
  SettingsFocusScope(
    target: state.uri.queryParameters[focusQuery],
    child: page,
  ),
);

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
  bool includeSearch = true,
  List<RouteBase> routes = const [],
}) {
  final commonRoutes = _commonBranchRoutes(
    observer,
    rootNavigatorKey: rootNavigatorKey,
    rootObserver: rootObserver,
    includeSearch: includeSearch,
    includeAppPages: true,
  );
  return StatefulShellBranch(
    navigatorKey: navigatorKey,
    observers: [observer],
    restorationScopeId: restorationScopeId,
    // Hands HomeBranchStack every branch's Navigator; it mounts them.
    preload: true,
    routes: [
      GoRoute(
        path: path,
        pageBuilder: (context, state) => _page(
          context,
          state,
          observer,
          // The bottom bar is a shell-level sibling of the branch strip;
          // this scaffold feeds it the root page's scrolling and draws it
          // under the routes that cover the root.
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
