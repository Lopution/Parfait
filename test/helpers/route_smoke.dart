import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';

import '../review/review_support.dart';
import 'fake_webview.dart';
import 'layout_fonts.dart';
import 'leak_tracking.dart';
import 'locale_layout.dart';

/// The route groups the smoke matrix splits into files: CI shards whole
/// files, and one file of every page would hold a shard for minutes.
enum SmokeGroup { entry, illust, novel, lists, settings }

/// One page of the app in the smoke matrix, in the states it can show.
class SmokePage {
  const SmokePage({
    this.at,
    this.setup = const ReviewSetup(),
    this.reads,
    this.empty,
  });

  /// A page whose content is the list [key] of the App API reply at [reads]:
  /// an empty reply is its empty state.
  SmokePage.feed(String this.reads, String key, {this.at})
    : setup = const ReviewSetup(),
      empty = ReviewSetup(api: {reads: reviewEmpty(key)});

  /// Where the page opens when not at its template: absolute, or under a
  /// stack root for a page every stack has.
  final String? at;

  /// The world of the loaded state.
  final ReviewSetup setup;

  /// The App API path the page's content comes from: its error state
  /// answers it with a failure.
  final String? reads;

  /// The world of the empty state, for a page that shows a list.
  final ReviewSetup? empty;
}

const smokeLocale = Locale('zh', 'CN');

/// Stack roots in the order pages every stack has are spread over them.
const smokeStackRoots = [
  '/recommended', '/ranking', '/new', '/search', '/settings', '/me', //
  '/downloads', '/reverse-image',
];

/// The page a route template shows: the template with its stack root
/// stripped for a page every stack has (`illust/:illustId`), else the
/// template. [common] are those pages, the routes under `/me`.
String smokePageOf(String template, Set<String> common) {
  for (final root in smokeStackRoots) {
    if (!template.startsWith('$root/')) continue;
    final rest = template.substring(root.length + 1);
    if (common.contains(rest)) return rest;
    // The search branch's own search pages drop the `search/` prefix.
    if (root == '/search' && common.contains('search/$rest')) {
      return 'search/$rest';
    }
  }
  return template;
}

/// Every route template of the app's router that shows a page.
List<String> smokeRouterTemplates() {
  final router = createPixivRouter();
  addTearDown(router.dispose);
  final templates = <String>[];
  void walk(List<RouteBase> routes, String parent) {
    for (final route in routes) {
      var path = parent;
      if (route is GoRoute) {
        path = route.path.startsWith('/')
            ? route.path
            : '${parent == '/' ? '' : parent}/${route.path}';
        if (route.builder != null || route.pageBuilder != null) {
          templates.add(path);
        }
      }
      walk(route.routes, path);
    }
  }

  walk(router.configuration.routes, '');
  return templates;
}

/// The location [path] opens at; a page every stack has takes the stack
/// root of [index] in [smokeStackRoots].
String smokeLocation(String path, int index) {
  if (path.startsWith('/')) return path;
  final root = smokeStackRoots[index % smokeStackRoots.length];
  if (root == '/search' && path.startsWith('search/')) return '/$path';
  return '$root/$path';
}

/// What a broken network hands back, by name: a gateway's HTML error
/// page, a body cut off mid-JSON, and no answer at all, which the client
/// times out. Pages that read the network take them in turn.
final smokeFailures = <(String, ReviewResponder)>[
  (
    '503 HTML',
    (_) async => http.Response(
      '<html><body><h1>503 Service Unavailable</h1></body></html>',
      503,
      headers: {'content-type': 'text/html'},
    ),
  ),
  (
    'cut JSON',
    (_) async => http.Response(
      '{"illusts": [{"id": 1, "title": "cut',
      200,
      headers: {'content-type': 'application/json'},
    ),
  ),
  ('timeout', reviewLoading()),
];

/// The device a [LayoutProfile] stands for: its size at density 1.
ReviewDevice smokeDevice(LayoutProfile profile) =>
    ReviewDevice(physicalSize: profile.size, dpr: 1);

/// Opens the whole app at [location] over a world from [setup] and checks
/// the page: no exception, UI text whole, still at [location], at rest (a
/// page still moving is still loading). A [timeout] scene checks its
/// loading state, then again once the client gives up.
/// [back] then pops and checks the page below: the route's parent. A
/// page with [content] shows what it opened for, not a message that it has
/// nothing to show; one without says it has nothing, or why.
Future<void> smokeScene(
  WidgetTester tester, {
  required String location,
  ReviewSetup setup = const ReviewSetup(),
  LayoutProfile profile = LayoutProfile.regular,
  ReviewDevice? device,
  double? textScale,
  Brightness brightness = Brightness.light,
  bool timeout = false,
  bool back = false,
  bool? content,
}) async {
  final world = (await tester.runAsync(() => ReviewWorld.open(setup)))!;
  await reviewScene(tester, () async {
    final router = await pumpReviewApp(
      tester,
      world: world,
      location: location,
      locale: smokeLocale,
      brightness: brightness,
      textScale: textScale ?? profile.textScale,
      device: device ?? smokeDevice(profile),
      fontFamilyFallback: layoutFontFallback,
    );
    var rest = await settleReview(tester, settle: !timeout);
    void expectIntact(String at) {
      expectLocaleLayoutIntact(tester, locale: smokeLocale, profile: profile);
      expect(router.state.uri.toString(), at, reason: 'opened $location');
    }

    void expectContent() {
      if (content == null) return;
      final messages = LocaleMessages.of(smokeLocale);
      final nothing = [
        for (final element in find.byType(RichText).evaluate())
          if (messages.keyOf(
                (element.renderObject! as RenderParagraph).text.toPlainText(),
              )
              case final key? when _nothing.hasMatch(key))
            key,
      ];
      final reason = '$location shows $nothing';
      if (content) {
        expect(
          nothing.where((key) => !_sectionHints.contains(key)),
          isEmpty,
          reason: reason,
        );
      } else {
        expect(nothing, isNotEmpty, reason: reason);
      }
    }

    expectIntact(location);
    if (timeout) {
      // Requests sent once the first gave up wait out their own timeout:
      // the ranking then warms the tabs next to the one on screen.
      for (var round = 0; round < 3; round++) {
        await tester.pump(
          PixivHttpClient.defaultRequestTimeout + const Duration(seconds: 1),
        );
        rest = await settleReview(tester);
        if (rest) break;
      }
      expectIntact(location);
    }
    expect(rest, isTrue, reason: '$location never came to rest');
    expectContent();
    if (!back) return;
    final matches = _flatten(
      router.routerDelegate.currentConfiguration.matches,
    );
    if (matches.length < 2) return;
    final parent = matches[matches.length - 2].matchedLocation;
    await tester.binding.handlePopRoute();
    await settleReview(tester);
    expect(router.state.matchedLocation, parent, reason: 'back from $location');
    expectLocaleLayoutIntact(tester, locale: smokeLocale, profile: profile);
  });
}

/// Keys of the messages a page shows in place of what it opened for.
final _nothing = RegExp(
  r'Empty|NoImages|NotFound|Failed|Unavailable|NoResults|NoContent|^error',
);

/// Hints for one section of a page the world cannot fill: the frame probe
/// has recorded nothing yet, muted works are kept only on the device, and
/// the test platform has no wallpaper colours.
const _sectionHints = {
  'heroAnomalyEmpty',
  'mutedEmpty',
  'followSystemColorsUnavailable',
};

List<RouteMatch> _flatten(List<RouteMatchBase> matches) => [
  for (final match in matches)
    if (match is ShellRouteMatch)
      ..._flatten(match.matches)
    else
      match as RouteMatch,
];

/// What every smoke file needs first in `main`: images fade in through
/// octo_image, and the login and Doubao pages build a web view.
void smokeHarness() {
  ignoreOctoImageFades();
  setUp(() => InAppWebViewPlatform.instance = FakeInAppWebViewPlatform());
}

/// Registers [group]'s pages in every state they show: loaded at the
/// regular profile, then back; loaded at the compact profile; empty;
/// failed.
void smokeMatrix(SmokeGroup group) {
  smokeHarness();
  for (final (index, MapEntry(key: template, value: page))
      in smokePages[group]!.entries.indexed) {
    final location = smokeLocation(page.at ?? template, index);
    testWidgets('$template loaded at $location', (tester) async {
      await smokeScene(
        tester,
        location: location,
        setup: page.setup,
        back: true,
        content: true,
      );
    });
    testWidgets('$template compact', (tester) async {
      await smokeScene(
        tester,
        location: location,
        setup: page.setup,
        profile: LayoutProfile.compact,
        content: true,
      );
    });
    if (page.empty case final empty?) {
      testWidgets('$template empty', (tester) async {
        await smokeScene(
          tester,
          location: location,
          setup: empty,
          content: false,
        );
      });
    }
    if (page.reads case final reads?) {
      final (failure, reply) = smokeFailures[index % smokeFailures.length];
      testWidgets('$template failed: $failure', (tester) async {
        var read = false;
        await smokeScene(
          tester,
          location: location,
          setup: ReviewSetup(
            api: {
              reads: (url) {
                read = true;
                return reply(url);
              },
            },
          ),
          timeout: failure == 'timeout',
          content: false,
        );
        expect(read, isTrue, reason: '$location never read $reads');
      });
    }
  }
}

/// Every page of the app, by the template [smokePageOf] gives it.
final smokePages = <SmokeGroup, Map<String, SmokePage>>{
  SmokeGroup.entry: {
    '/splash': const SmokePage(),
    for (final path in const [
      '/welcome', '/welcome/language', '/user-agreement', '/login', //
      '/login/web', '/login/callback',
    ])
      path: const SmokePage(setup: ReviewSetup(signedIn: false)),
    '/recommended': SmokePage.feed('/v1/illust/recommended', 'illusts'),
    '/ranking': SmokePage.feed('/v1/illust/ranking', 'illusts'),
    '/new': SmokePage.feed('/v2/illust/follow', 'illusts'),
    // No trending tags leave the search page as it is: nothing to say.
    '/search': const SmokePage(reads: '/v1/trending-tags/illust'),
    '/settings': const SmokePage(),
    '/me': const SmokePage(reads: '/v1/user/detail'),
    '/downloads': const SmokePage(
      setup: ReviewSetup(downloadGroups: 1, downloadSingles: 2),
      empty: ReviewSetup(),
    ),
    '/reverse-image': const SmokePage(),
  },
  SmokeGroup.illust: {
    // Works no feed has loaded: a failed detail has no snapshot to show.
    'illust/:illustId': const SmokePage(at: 'illust/4321', reads: _detail),
    'illust/:illustId/viewer/:page': const SmokePage(
      at: 'illust/4322/viewer/1',
      reads: _detail,
    ),
    'illust/:illustId/comments': SmokePage.feed(
      '/v3/illust/comments',
      'comments',
      at: 'illust/1001/comments',
    ),
    'illust/:illustId/comments/:rootCommentId': SmokePage.feed(
      '/v2/illust/comment/replies',
      'comments',
      at: 'illust/1001/comments/1',
    ),
    'user/:userId': SmokePage(
      at: 'user/3000',
      reads: '/v1/user/detail',
      empty: ReviewSetup(api: {'/v1/user/illusts': reviewEmpty('illusts')}),
    ),
    'series/:seriesId': const SmokePage(
      at: 'series/500',
      reads: '/v1/illust/series',
    ),
    'spotlight': SmokePage.feed('/v1/spotlight/articles', 'spotlight_articles'),
    'spotlight/article/:articleId': const SmokePage(
      at: 'spotlight/article/101',
    ),
    'profile/:userId/edit': const SmokePage(
      at: 'profile/100/edit',
      reads: '/v1/user/detail',
    ),
  },
  SmokeGroup.novel: {
    'novel/:novelId': const SmokePage(
      at: 'novel/2000',
      reads: '/v2/novel/detail',
    ),
    'novel/:novelId/comments': SmokePage.feed(
      '/v3/novel/comments',
      'comments',
      at: 'novel/2000/comments',
    ),
    'novel/:novelId/comments/:rootCommentId': SmokePage.feed(
      '/v2/novel/comment/replies',
      'comments',
      at: 'novel/2000/comments/1',
    ),
    'novel-ranking': SmokePage.feed('/v1/novel/ranking', 'novels'),
    'new-novels': SmokePage.feed('/v1/novel/follow', 'novels'),
    'local-novels': const SmokePage(
      setup: ReviewSetup(localNovels: 3),
      empty: ReviewSetup(),
    ),
    'local-novels/:localId': const SmokePage(
      at: 'local-novels/1',
      setup: ReviewSetup(localNovels: 1),
    ),
    'watchlist': SmokePage.feed('/v1/watchlist/manga', 'series'),
  },
  SmokeGroup.lists: {
    'history': SmokePage(
      setup: ReviewSetup(history: reviewHistory()),
      empty: const ReviewSetup(),
    ),
    'watchlater': const SmokePage(
      setup: ReviewSetup(watchlater: 3),
      empty: ReviewSetup(),
    ),
    'bookmarks/tags': SmokePage.feed(
      '/v1/user/bookmark-tags/illust',
      'bookmark_tags',
    ),
    'bookmarks/tag': SmokePage.feed(
      '/v1/user/bookmarks/illust',
      'illusts',
      at: 'bookmarks/tag?tag=cat',
    ),
    'tag/:keyword': SmokePage.feed(
      '/v1/search/illust',
      'illusts',
      at: 'tag/cat',
    ),
    // Suggestions are a bonus: none, or none in time, leave the input be.
    'search/input': const SmokePage(at: 'search/input?q=cat'),
    'search/results': SmokePage.feed(
      '/v1/search/illust',
      'illusts',
      at: 'search/results?q=cat&type=illust',
    ),
  },
  SmokeGroup.settings: {
    for (final path in const [
      'theme', 'language', 'translate', 'translate/doubao-login', 'network', //
      'network/probe', 'network/advanced', 'frame-probe', 'browse', 'motion',
      'navigation', 'navigation/bottom-bar', 'download',
      'download/destination', 'backup', 'about', 'about/licenses',
    ])
      '/settings/$path': const SmokePage(),
    '/settings/translate/credentials/:provider': const SmokePage(
      at: '/settings/translate/credentials/baidu',
    ),
    '/settings/tasks': const SmokePage(
      setup: ReviewSetup(downloadSingles: 2),
      empty: ReviewSetup(),
    ),
    '/settings/all': const SmokePage(),
    '/settings/account': const SmokePage(reads: '/v1/user/ai-show-settings'),
    // Muted items are the device's; the server's list merges in when it
    // answers, and the next visit tries again when it does not.
    '/settings/muted': SmokePage(
      empty: ReviewSetup(
        api: {
          '/v1/mute/list': reviewJson({
            'muted_tags': const <Object?>[],
            'muted_users': const <Object?>[],
            'mute_limit_count': 30,
          }),
        },
      ),
    ),
  },
};

const _detail = '/v1/illust/detail';
