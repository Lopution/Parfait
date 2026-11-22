import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/bookmark/bookmark_models.dart';
import '../../core/entity/comment_entity.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/settings/app_settings.dart';
import '../../core/user/user_repository.dart';
import '../../l10n/context.dart';
import '../haptics/app_haptics.dart';
import '../image_tier_cache.dart';
import '../layout/form_factor.dart';
import '../pixiv_image.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/author_summary.dart';
import '../widgets/feed/feed_text_warmup.dart';
import '../widgets/feed/illust_pager_source.dart';
import '../widgets/tag_chips.dart';
import '../window/desktop_command_bar_scope.dart';
import 'route_extras.dart';
import 'route_query_codecs.dart';
import 'viewer_session.dart';

export 'route_extras.dart'
    show IllustRouteExtra, ImageViewerRouteExtra, NovelRouteExtra;

/// Navigation facade — lightweight, zero-feature-page library for callers to
/// push typed locations onto `GoRouter` without pulling the full router table
/// (`routes.dart`) into their compile unit.
const _branchRoots = <String>[
  '/recommended',
  '/ranking',
  '/new',
  '/search',
  '/settings',
];

const _overlayRoots = <String>['/me', '/reverse-image', '/downloads'];

const _stackRoots = <String>[..._branchRoots, ..._overlayRoots];

String livePathOf(GoRouter router) {
  try {
    return router.state.uri.path;
  } on Object {
    final config = router.routerDelegate.currentConfiguration;
    if (config.isNotEmpty) return config.uri.path;
    return router.routeInformationProvider.value.uri.path;
  }
}

String? stackRootOf(String path) {
  for (final root in _stackRoots) {
    if (path == root || path.startsWith('$root/')) return root;
  }
  return null;
}

String currentStackRoot(BuildContext context) {
  final path = livePathOf(GoRouter.of(context));
  return stackRootOf(path) ?? '/recommended';
}

/// Whether the shell shows the rail at this window's width.
bool hasShellRail(BuildContext context) =>
    FormFactor.of(context).hasRail(MediaQuery.sizeOf(context).width);

/// Opens the download tasks screen from process-level triggers (tray menu).
void openDownloadsFromRouter(GoRouter router, {bool? rail}) {
  final path = livePathOf(router);
  if (_isPreHomePath(path)) return;
  if (path == '/downloads' || path.endsWith('/downloads')) return;
  final effectiveRail = rail ?? _hasRailFromRouter(router);
  unawaited(
    router.push<void>(
      appPageLocation(router, 'downloads', rail: effectiveRail),
    ),
  );
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

/// Where an app-level page ([leaf]: `me`, `downloads`) opens. Beside a
/// [rail], inside the branch on screen, so the rail stays; over everything on
/// the root navigator on a phone, or while a root page (the viewer) is on top.
String appPageLocation(GoRouter router, String leaf, {required bool rail}) {
  if (rail) {
    final root = stackRootOf(router.state.uri.path);
    final inBranch = '$root/$leaf';
    if (_branchRoots.contains(root) && pushStaysInStack(router, inBranch)) {
      return inBranch;
    }
  }
  return '/$leaf';
}

Future<void> pushRoute(
  BuildContext context,
  String location, {
  Object? extra,
}) async {
  final router = GoRouter.of(context);
  assert(
    pushStaysInStack(router, location),
    'push of $location leaves the stack of ${router.state.uri}',
  );
  await context.push<void>(location, extra: extra);
}

/// Swaps the top page for [location] under a fresh page key, so the new page
/// runs the normal entrance transition. `context.replace` keeps the key and
/// swaps without one — right for updating a page's own query, wrong for
/// moving on to a different page.
Future<void> pushReplacementRoute(
  BuildContext context,
  String location, {
  Object? extra,
}) async {
  final router = GoRouter.of(context);
  assert(
    pushStaysInStack(router, location),
    'push of $location leaves the stack of ${router.state.uri}',
  );
  await router.pushReplacement<void>(location, extra: extra);
}

/// Branch locations must be pushed from their own visible branch stack. A
/// branch push from an overlay, another branch, or a root-level page such as
/// the viewer would create a second shell or bury the target below that page.
bool pushStaysInStack(GoRouter router, String location) {
  final target = stackRootOf(Uri.parse(location).path);
  if (target == null || !_branchRoots.contains(target)) return true;
  final current = router.routerDelegate.currentConfiguration;
  final currentRoot = stackRootOf(current.uri.path);
  if (currentRoot == null) {
    // Standalone root-level hosts (for example a deep-link test router) do
    // not have a shell branch to preserve; their root search route is safe.
    return true;
  }
  return currentRoot == target &&
      current.last.route.parentNavigatorKey !=
          router.routerDelegate.navigatorKey;
}

Future<void> openIllust(
  BuildContext context,
  int illustId, {
  IllustEntity? initialEntity,
  String heroScope = 'feed',
  String? heroImageUrl,
  int? heroImageDecodeWidth,
  IllustPagerSource? pagerSource,
}) async {
  await pushRoute(
    context,
    '${currentStackRoot(context)}/illust/$illustId',
    extra: IllustRouteExtra(
      entity: initialEntity,
      heroScope: heroScope,
      heroImageUrl: heroImageUrl,
      heroImageDecodeWidth: heroImageDecodeWidth,
      pagerSource: pagerSource,
    ),
  );
}

/// The text [openIllust]'s page for [entity] shapes as it builds, to lay
/// out ahead of the push ([FeedTextWarmup]).
List<WarmText> illustDetailWarmTexts(
  BuildContext context,
  IllustEntity entity,
) {
  final titleStyle = warmStyle(
    context,
    FuncSemanticTokens.of(context).workTitle,
    inherited: Theme.of(context).textTheme.bodyMedium,
  );
  final account = entity.user.account.isEmpty
      ? null
      : '@${entity.user.account}';
  return [
    (
      span: TextSpan(text: entity.title, style: titleStyle),
      locale: Localizations.maybeLocaleOf(context),
      strutStyle: const StrutStyle().inheritFromTextStyle(titleStyle),
    ),
    ...AuthorSummary.warmTexts(
      context,
      name: entity.user.name,
      account: account,
    ),
    for (final tag in entity.tags)
      TagChip.warmText(
        context,
        label: tag.name,
        translated: tag.translatedName,
      ),
  ];
}

Future<void> openUser(BuildContext context, int userId) async {
  await pushRoute(context, '${currentStackRoot(context)}/user/$userId');
}

Future<void> openIllustSeries(BuildContext context, int seriesId) async {
  await pushRoute(context, '${currentStackRoot(context)}/series/$seriesId');
}

Future<void> openNovelSeries(BuildContext context, int seriesId) async {
  await pushRoute(
    context,
    '${currentStackRoot(context)}/novel-series/$seriesId',
  );
}

Future<void> openSpotlight(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/spotlight');
}

Future<void> openSpotlightArticle(
  BuildContext context, {
  required int articleId,
  String? articleUrl,
}) async {
  final location = Uri(
    path: '${currentStackRoot(context)}/spotlight/article/$articleId',
    queryParameters: {'url': ?articleUrl},
  ).toString();
  await pushRoute(context, location);
}

/// Own-profile tabs another page can open the profile on (the "me"
/// dashboard's bookmarks and following entries).
enum MeTab { bookmarks, following }

Future<void> openMe(BuildContext context, {MeTab? tab}) async {
  // The profile is an app-level page: it opens on whatever stack is
  // showing (the settings branch included) instead of switching branches.
  await context.push<void>(
    Uri(
      path: appPageLocation(
        GoRouter.of(context),
        'me',
        rail: hasShellRail(context),
      ),
      queryParameters: tab == null ? null : {'tab': tab.name},
    ).toString(),
  );
}

/// App settings are the fifth home destination: opening them switches the
/// shell branch rather than pushing a page over it.
Future<void> openSettings(BuildContext context) async {
  GoRouter.of(context).go('/settings');
}

/// Pushes the full settings index page on top of the current navigation stack.
Future<void> openAllSettings(BuildContext context) async {
  await GoRouter.of(context).push<void>('/settings/all');
}

/// Pushes the account management page.
Future<void> openAccountSettings(BuildContext context) async {
  await GoRouter.of(context).push<void>('/settings/account');
}

/// The update prompt can be shown above any route, including root overlays.
/// Going to the about page keeps a single home shell instead of pushing a
/// settings branch below the page that displayed the prompt.
void goToAbout(GoRouter router) => router.go('/settings/about');

/// [atPixivPage] opens at that Pixiv page rather than the saved place.
Future<void> openNovel(
  BuildContext context,
  int novelId, {
  int? atPixivPage,
}) async {
  await pushRoute(
    context,
    '${currentStackRoot(context)}/novel/$novelId',
    extra: atPixivPage == null
        ? null
        : NovelRouteExtra(atPixivPage: atPixivPage),
  );
}

Future<void> openNovelRanking(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/novel-ranking');
}

/// From the novel ranking to the illust ranking without stacking a second
/// page: a novel ranking pushed from the ranking root pops back to it; one
/// in another stack (a link) goes to the ranking branch.
void openIllustRanking(BuildContext context) {
  final router = GoRouter.of(context);
  if (currentStackRoot(context) == '/ranking' && router.canPop()) {
    router.pop();
  } else {
    router.go('/ranking');
  }
}

Future<void> openNewNovels(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/new-novels');
}

/// Download tasks are an app-level page on the current stack.
Future<void> openDownloadTasks(BuildContext context) async {
  await pushRoute(
    context,
    appPageLocation(
      GoRouter.of(context),
      'downloads',
      rail: hasShellRail(context),
    ),
  );
}

/// Binds the prompt action to the router while the submitting page is
/// alive, so it remains valid after that page is popped or disposed.
void showDownloadSubmittedSnackBar(
  BuildContext context, {
  bool alreadyQueued = false,
}) {
  final router = GoRouter.maybeOf(context);
  final rail = hasShellRail(context);
  final l10n = context.l10n;
  if (!alreadyQueued) AppHaptics.success();
  showAppSnackBar(
    context,
    alreadyQueued ? l10n.downloadAlreadyQueued : l10n.downloadQueuedMessage,
    action: router == null
        ? null
        : PromptAction(
            label: l10n.downloadViewResult,
            onPressed: () => unawaited(
              router.push<void>(
                appPageLocation(router, 'downloads', rail: rail),
              ),
            ),
          ),
  );
}

/// Switches the home shell to [destination] from a page inside it: the
/// way to a destination the user took off the bar.
void openHomeDestination(BuildContext context, HomeDestination destination) =>
    StatefulNavigationShell.of(context).goBranch(destination.branchIndex);

Future<void> openWatchLater(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/watchlater');
}

Future<void> openWatchlist(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/watchlist');
}

Future<void> openNovelMarkers(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/novel-markers');
}

Future<void> openLocalNovels(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/local-novels');
}

Future<void> openLocalNovelReader(BuildContext context, int localId) async {
  await pushRoute(
    context,
    '${currentStackRoot(context)}/local-novels/$localId',
  );
}

Future<void> openBookmarkTags(
  BuildContext context, {
  required BookmarkEntityType kind,
  required UserRestrict restrict,
}) async {
  final location = Uri(
    path: '${currentStackRoot(context)}/bookmarks/tags',
    queryParameters: {
      'kind': kind.name,
      'restrict': bookmarkRestrictFromUser(restrict).name,
    },
  ).toString();
  await pushRoute(context, location);
}

Future<void> openBookmarkTagFeed(
  BuildContext context, {
  required String tag,
  required BookmarkEntityType kind,
  required BookmarkRestrict restrict,
}) async {
  final location = Uri(
    path: '${currentStackRoot(context)}/bookmarks/tag',
    queryParameters: {'tag': tag, 'kind': kind.name, 'restrict': restrict.name},
  ).toString();
  await pushRoute(context, location);
}

Future<void> openReverseImageSearch(
  BuildContext context, {
  ReverseImageInputReference? initialReference,
}) async {
  await pushRoute(context, '/reverse-image', extra: initialReference);
}

/// Pre-hides `DesktopCommandBar` synchronously before pushing a viewer route so
/// Frame 0 / Hero measurement sees the full dark-stage viewport, releasing the
/// transitional token after the route mounts or if the push exits early.
Future<void> _pushWithHiddenCommandBar(
  BuildContext context,
  Future<void> Function() push,
) async {
  final controller = DesktopCommandBarScope.controllerOf(context);
  if (controller == null) {
    await push();
    return;
  }
  final token = Object();
  var released = false;
  void release() {
    if (released) return;
    released = true;
    controller.setHidden(token, false);
  }

  controller.setHidden(token, true);
  WidgetsBinding.instance.addPostFrameCallback((_) => release());
  try {
    await push();
  } finally {
    release();
  }
}

Future<void> openImageViewer(
  BuildContext context, {
  required IllustEntity entity,
  required int page,
  required ViewQuality quality,
  String? heroScope,
}) async {
  // Each viewer entry starts a fresh chrome session (default visible);
  // in-session page swaps go through replaceImageViewerPage instead and
  // keep the user's hidden-chrome choice.
  beginImageViewerSession();
  // Warm the tapped page's viewer URL before the route mounts. precacheImage
  // shares the in-flight decode stream for the same provider key, so the
  // viewer's first frame lands on an already-resolving entry instead of a
  // cold placeholder — the flash seen when zooming while the detail page
  // was still loading. Decodes at the viewer's preview width, as the page.
  unawaited(
    PixivImage.preload(
      context,
      entity.viewerUrlAt(page, quality),
      tierKey: entity.imageTierKeyAt(page),
      tier: quality.tier,
      memCacheWidth: viewerPreviewDecodeWidth(context),
      priority: ImageFetchPriority.foreground,
      // A context that unmounts mid-push (branch switch racing the tap)
      // makes the deferred precache throw — best-effort, so swallow.
    ).then((_) {}, onError: (_, _) {}),
  );
  await _pushWithHiddenCommandBar(
    context,
    () => pushRoute(
      context,
      '${currentStackRoot(context)}/illust/${entity.id}/viewer/$page'
      '?quality=${quality.code}',
      extra: ImageViewerRouteExtra(
        urls: entity.viewerUrls(quality),
        entity: entity,
        heroScope: heroScope,
        entryPage: page,
      ),
    ),
  );
}

/// A Pixiv work's pages in the viewer, opened from outside its detail page
/// (a novel's illustration): the viewer loads the work itself.
Future<void> openIllustViewer(
  BuildContext context, {
  required int illustId,
  required int page,
  required ViewQuality quality,
}) async {
  beginImageViewerSession();
  await _pushWithHiddenCommandBar(
    context,
    () => pushRoute(
      context,
      '${currentStackRoot(context)}/illust/$illustId/viewer/$page'
      '?quality=${quality.code}',
    ),
  );
}

Future<void> openNovelImage(
  BuildContext context,
  int novelId,
  String imageId,
) async {
  beginImageViewerSession();
  await _pushWithHiddenCommandBar(
    context,
    () => pushRoute(
      context,
      '${currentStackRoot(context)}/novel/$novelId/image/$imageId',
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
    '${currentStackRoot(context)}/illust/$illustId/viewer/$page'
    '?quality=${quality.code}',
    extra: extra,
  );
}

Future<void> openIllustComments(BuildContext context, int illustId) async {
  if (illustId <= 0) return;
  await pushRoute(
    context,
    '${currentStackRoot(context)}/illust/$illustId/comments',
  );
}

Future<void> openNovelComments(BuildContext context, int novelId) async {
  if (novelId <= 0) return;
  await pushRoute(
    context,
    '${currentStackRoot(context)}/novel/$novelId/comments',
  );
}

Future<void> openCommentReplies(
  BuildContext context,
  CommentEntity rootComment,
) async {
  final workPath = switch (rootComment.kind) {
    CommentWorkKind.illust => 'illust',
    CommentWorkKind.novel => 'novel',
  };
  await pushRoute(
    context,
    '${currentStackRoot(context)}/$workPath/${rootComment.workId}'
    '/comments/${rootComment.id}',
    extra: rootComment,
  );
}

Future<void> openHistory(BuildContext context) async {
  await pushRoute(context, '${currentStackRoot(context)}/history');
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
  await pushRoute(context, location);
}

Future<void> openProfileEdit(BuildContext context, int userId) async {
  await pushRoute(context, '${currentStackRoot(context)}/profile/$userId/edit');
}

Future<void> openTagSearch(BuildContext context, String keyword) async {
  await pushRoute(
    context,
    '${currentStackRoot(context)}/tag/${Uri.encodeComponent(keyword)}',
  );
}
