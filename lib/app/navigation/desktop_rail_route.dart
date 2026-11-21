import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Sub-destinations hosted inside branch 4 (`/settings`) that appear as
/// dedicated entries on the desktop [ShellRail] (`NAV-20`).
enum DesktopRailSection { none, bookmarks, downloads, settings }

const _settingsSubPathSegments = <String>{
  'all',
  'account',
  'theme',
  'language',
  'translate',
  'motion',
  'browse',
  'navigation',
  'muted',
  'network',
  'download',
  'backup',
  'tasks',
  'about',
  'frame-probe',
};

/// Whether [path] belongs to the full Settings workspace (`/settings/all` or
/// any settings leaf page) rather than `我的` (`/settings`) or its library
/// sub-pages (`me`, `downloads`, `history`, etc.).
bool isSettingsSubPath(String? path) {
  if (path == null || !path.startsWith('/settings/')) return false;
  final rest = path.substring('/settings/'.length);
  return _settingsSubPathSegments.contains(rest.split('/').first);
}

ShellRouteMatch? _findBranchMatch(
  List<RouteMatchBase> matches,
  GlobalKey<NavigatorState> branchKey,
) {
  for (final match in matches) {
    if (match is ShellRouteMatch) {
      if (match.navigatorKey == branchKey) return match;
      final nested = _findBranchMatch(match.matches, branchKey);
      if (nested != null) return nested;
    }
  }
  return null;
}

Uri? _uriOfMatch(RouteMatchBase match, Uri configUri) {
  if (match is ImperativeRouteMatch) return match.matches.uri;
  final location = match.matchedLocation;
  if (configUri.path == location) return configUri;
  return Uri.tryParse(location);
}

/// Top-most URI currently visible inside [branchKey]'s navigator.
Uri? branchTopUri(GoRouter router, GlobalKey<NavigatorState> branchKey) {
  final config = router.routerDelegate.currentConfiguration;
  final branch = _findBranchMatch(config.matches, branchKey);
  if (branch == null || branch.matches.isEmpty) return null;
  return _uriOfMatch(branch.matches.last, config.uri);
}

/// Resolves which dedicated desktop rail section owns branch 4's current stack.
///
/// Walks from the top-most match downward so detail pages pushed from `收藏`,
/// `下载`, or `设置` keep their originating rail section highlighted instead of
/// snapping back to `我的`.
DesktopRailSection desktopRailSectionOfBranch(
  GoRouter router,
  GlobalKey<NavigatorState> branchKey,
) {
  final config = router.routerDelegate.currentConfiguration;
  final branch = _findBranchMatch(config.matches, branchKey);
  if (branch == null || branch.matches.isEmpty) return DesktopRailSection.none;
  for (var i = branch.matches.length - 1; i >= 0; i--) {
    final section = desktopRailSectionForUri(
      _uriOfMatch(branch.matches[i], config.uri),
    );
    if (section != DesktopRailSection.none) return section;
  }
  return DesktopRailSection.none;
}

/// Maps a single branch-4 [uri] to its dedicated desktop rail section, if any.
DesktopRailSection desktopRailSectionForUri(Uri? uri) {
  if (uri == null) return DesktopRailSection.none;
  final path = uri.path;
  if (isSettingsSubPath(path)) return DesktopRailSection.settings;
  if (path == '/settings/downloads') return DesktopRailSection.downloads;
  if (path == '/settings/me') {
    final tab = uri.queryParameters['tab'];
    if (tab == null || tab == 'bookmarks') return DesktopRailSection.bookmarks;
  }
  return DesktopRailSection.none;
}
