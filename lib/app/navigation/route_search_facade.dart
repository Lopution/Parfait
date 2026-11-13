part of 'routes.dart';

String _searchPath(BuildContext context, String leaf) =>
    _searchLeafPath(_stackRootOf(GoRouter.of(context).state.uri.path), leaf);

/// Search leaves live under the search branch itself and under every other
/// branch's `/search`.
String _searchLeafPath(String? root, String leaf) {
  if (root == null) return '/search/$leaf';
  return root == '/search' ? '/search/$leaf' : '$root/search/$leaf';
}

/// Opens the search input. On the wide shell [anchor] — the search entry's
/// global rectangle, asked again whenever the panel re-lays out — docks the
/// input under it as a panel (R10); without one, or on a phone's layout,
/// the full input page opens.
Future<void> openSearchInput(
  BuildContext context, {
  String initialKeyword = '',
  SearchResultType type = SearchResultType.illust,
  Rect? Function()? anchor,
}) async {
  final router = GoRouter.of(context);
  final root = _stackRootOf(router.state.uri.path);
  final trigger = anchor?.call();
  if (trigger != null && _hasRail(context)) {
    final outcome = await showDockedSearch(
      context,
      anchor: trigger,
      anchorOf: anchor,
      initialKeyword: initialKeyword,
      type: type,
    );
    switch (outcome) {
      case DockedSearchSubmitted(:final query):
        // The destination stays under the results it opens.
        await _moveToSearchResults(router, root, query);
      case DockedSearchShortcut(:final shortcut):
        await _openSearchShortcut(router, root, shortcut);
      case DockedSearchNarrowed(
        :final keyword,
        :final type,
        :final illustFilters,
        :final novelFilters,
      ):
        // The header's search entry is gone from the phone layout, so the
        // widget's context may be too; the router is not.
        final location = _searchInputLocationFor(root, keyword, type);
        assert(pushStaysInStack(router, location));
        await router.push<void>(
          location,
          extra: _SearchInputDraft(
            keyword: keyword,
            type: type,
            illustFilters: illustFilters,
            novelFilters: novelFilters,
          ),
        );
      case null:
        break;
    }
    return;
  }
  await _push(context, _searchInputLocationFor(root, initialKeyword, type));
}

/// The result page's query field (R9): on the wide shell the docked input
/// opens under [anchor] and submitting replaces the results in place
/// (NAV-06); elsewhere the input page takes the results' place.
Future<void> editSearchFromResults(
  BuildContext context, {
  required Rect? Function()? anchor,
  required String keyword,
  required SearchResultType type,
}) async {
  final trigger = anchor?.call();
  if (trigger == null || !_hasRail(context)) {
    return swapToSearchInput(context, keyword: keyword, type: type);
  }
  final router = GoRouter.of(context);
  final root = _stackRootOf(router.state.uri.path);
  final outcome = await showDockedSearch(
    context,
    anchor: trigger,
    anchorOf: anchor,
    initialKeyword: keyword,
    type: type,
  );
  switch (outcome) {
    case DockedSearchSubmitted(:final query):
      await _moveToSearchResults(router, root, query, replaceCurrent: true);
    case DockedSearchShortcut(:final shortcut):
      await _openSearchShortcut(router, root, shortcut, replaceCurrent: true);
    case DockedSearchNarrowed(
      :final keyword,
      :final type,
      :final illustFilters,
      :final novelFilters,
    ):
      final location = _searchInputLocationFor(root, keyword, type);
      assert(pushStaysInStack(router, location));
      await router.pushReplacement<void>(
        location,
        extra: _SearchInputDraft(
          keyword: keyword,
          type: type,
          illustFilters: illustFilters,
          novelFilters: novelFilters,
        ),
      );
    case null:
      break;
  }
}

void replaceSearchInput(
  BuildContext context, {
  required String keyword,
  required SearchResultType type,
}) {
  context.replace(_searchInputLocation(context, keyword, type));
}

/// Results → input for editing the query: the input page takes the results'
/// place, so the search stack never grows past input or results.
Future<void> swapToSearchInput(
  BuildContext context, {
  required String keyword,
  required SearchResultType type,
}) => _pushReplacement(context, _searchInputLocation(context, keyword, type));

String _searchInputLocation(
  BuildContext context,
  String keyword,
  SearchResultType type,
) => _searchInputLocationFor(
  _stackRootOf(GoRouter.of(context).state.uri.path),
  keyword,
  type,
);

String _searchInputLocationFor(
  String? root,
  String keyword,
  SearchResultType type,
) => Uri(
  path: _searchLeafPath(root, 'input'),
  queryParameters: {'q': keyword, 'type': type.name},
).toString();

void replaceRankingMode(
  BuildContext context,
  RankingMode mode,
  DateTime? date,
) {
  final location = Uri(
    path: '/ranking',
    queryParameters: _rankingQueryParameters(mode.name, date),
  ).toString();
  context.replace(location);
}

/// Novel ranking lives on a pushed common route (`<branch>/novel-ranking`),
/// so the replaced location keeps the branch prefix of the stack it was
/// opened from — same rule [openNovelRanking] uses.
void replaceNovelRankingMode(
  BuildContext context,
  NovelRankingMode mode,
  DateTime? date,
) {
  final location = Uri(
    path: '${_currentStackRoot(context)}/novel-ranking',
    queryParameters: _rankingQueryParameters(mode.name, date),
  ).toString();
  context.replace(location);
}

void replaceRecommendedType(BuildContext context, RecommendedContentType type) {
  final location = Uri(
    path: '/recommended',
    queryParameters: {'type': type.name},
  ).toString();
  context.replace(location);
}

void replaceNewFeed(BuildContext context, NewFeedScope scope) {
  final location = Uri(
    path: '/new',
    queryParameters: {'scope': scope.name},
  ).toString();
  context.replace(location);
}

/// New novels live on a pushed common route (`<branch>/new-novels`), like
/// [replaceNovelRankingMode].
void replaceNewNovelScope(BuildContext context, NewFeedScope scope) {
  final location = Uri(
    path: '${_currentStackRoot(context)}/new-novels',
    queryParameters: {'scope': scope.name},
  ).toString();
  context.replace(location);
}

Future<void> openSearchResults(
  BuildContext context,
  SearchQuery query, {
  bool replaceCurrent = false,
}) async {
  if (query.keyword.trim().isEmpty) {
    showAppSnackBar(context, context.l10n.searchInputEmpty);
    return;
  }
  final router = GoRouter.of(context);
  await _moveToSearchResults(
    router,
    _stackRootOf(router.state.uri.path),
    query,
    replaceCurrent: replaceCurrent,
  );
}

/// Pushes the results, or replaces the current page with them, without a
/// widget context: the docked panel's host may be gone from the tree by the
/// time it closes (R10).
Future<void> _moveToSearchResults(
  GoRouter router,
  String? root,
  SearchQuery query, {
  bool replaceCurrent = false,
}) async {
  final keyword = query.keyword.trim();
  // An id or a pixiv link opens what it names instead of searching.
  final shortcut = searchShortcutFor(keyword, query.type);
  if (shortcut != null) {
    return _openSearchShortcut(
      router,
      root,
      shortcut,
      replaceCurrent: replaceCurrent,
    );
  }
  final location = Uri(
    path: _searchLeafPath(root, 'results'),
    queryParameters: _searchQueryParameters(query),
  ).toString();
  assert(pushStaysInStack(router, location));
  if (replaceCurrent) {
    await router.pushReplacement<void>(location);
  } else {
    await router.push<void>(location);
  }
}

/// Opens what the draft names, once the docked panel that showed it has
/// closed. From a destination the page is pushed over it; from the results
/// it takes their place (NAV-06).
Future<void> _openSearchShortcut(
  GoRouter router,
  String? root,
  SearchShortcut shortcut, {
  bool replaceCurrent = false,
}) async {
  final location = _shortcutLocation(root ?? '/recommended', shortcut);
  assert(pushStaysInStack(router, location));
  if (replaceCurrent) {
    await router.pushReplacement<void>(location);
  } else {
    await router.push<void>(location);
  }
}

String _shortcutLocation(String root, SearchShortcut shortcut) {
  final path = switch (shortcut.kind) {
    SearchShortcutKind.illust => 'illust',
    SearchShortcutKind.novel => 'novel',
    SearchShortcutKind.user => 'user',
  };
  return '$root/$path/${shortcut.id}';
}

/// Opens what an id or pixiv link names in place of the search input page.
Future<void> swapToSearchShortcut(
  BuildContext context,
  SearchShortcut shortcut,
) => _pushReplacement(
  context,
  _shortcutLocation(_currentStackRoot(context), shortcut),
);

void replaceSearchResults(BuildContext context, SearchQuery query) {
  final keyword = query.keyword.trim();
  if (keyword.isEmpty) {
    showAppSnackBar(context, context.l10n.searchInputEmpty);
    return;
  }
  final location = Uri(
    path: _searchPath(context, 'results'),
    queryParameters: _searchQueryParameters(query),
  ).toString();
  context.replace(location);
}
