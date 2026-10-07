import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/spotlight/article_parser.dart';
import 'package:parfait/core/spotlight/spotlight_article_controller.dart';
import 'package:parfait/core/spotlight/spotlight_models.dart';
import 'package:parfait/core/spotlight/spotlight_repository.dart';
import 'package:parfait/features/spotlight/spotlight_article_page.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/image_network.dart';
import 'helpers/spotlight_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

const _articleHtml = '''
<!DOCTYPE html>
<html><body>
<article>
  <header>
    <h1 class="am__title">特辑标题</h1>
    <p class="am__description">文章描述文本</p>
  </header>
  <div class="am__body">
    <p>开篇段落 <a href="https://www.pixiv.net/artworks/12345">作品链接</a> 收尾。</p>
    <h2>小节标题</h2>
    <p><img src="https://i.pximg.net/c/600x600/spotlight/x.jpg"></p>
    <div class="am__work">
      <a href="/users/42"><img src="https://i.pximg.net/user-profile/42.jpg"></a>
      <h3><a href="/artworks/777">作品标题</a></h3>
      <p class="am__work__user-name">by <a href="/users/42">作者名</a></p>
      <a href="/artworks/777"><img src="https://i.pximg.net/t/777.jpg"></a>
    </div>
  </div>
</article>
</body></html>
''';

const _featureHtml = '''
<html><body>
<article>
  <header><h1>feature 特辑</h1></header>
  <div class="am__body">
    <div class="_feature">
      <p>第一段</p>
      <h3>三级标题</h3>
      <img src="https://s.pximg.net/spotlight/y.jpg">
    </div>
  </div>
</article>
</body></html>
''';

/// Records what the article page hands to the platform share boundary.
class _RecordingShareService implements ShareService {
  SharePayload? lastPayload;
  Rect? lastOrigin;
  ShareOutcome outcome = ShareOutcome.openedSheet;

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    lastPayload = payload;
    lastOrigin = sharePositionOrigin;
    return outcome;
  }
}

/// Captures outbound `launch` calls on the url_launcher method channel —
/// the app calls `launchUrl`, which the platform interface forwards as a
/// `launch` invocation carrying the resolved url.
List<String> mockUrlLauncher(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    if (call.method == 'launch') {
      launched.add((call.arguments as Map)['url'] as String);
    }
    return true;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  return launched;
}

/// `find.textRange`/`tapOnText` only index plain `RichText` — paragraph
/// text inside `SelectableText.rich` lives in an `EditableText`. Resolve
/// the link's selection boxes from the RenderEditable and tap its center.
Future<void> tapSelectableLink(WidgetTester tester, String pattern) async {
  final editables = find
      .descendant(
        of: find.byType(SelectableText),
        matching: find.byType(EditableText),
      )
      .evaluate()
      .map((element) => element.widget as EditableText)
      .where((editable) => editable.controller.text.contains(pattern));
  final editable = editables.single;
  final start = editable.controller.text.indexOf(pattern);
  final render = tester
      .state<EditableTextState>(find.byWidget(editable))
      .renderEditable;
  final boxes = render.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + pattern.length),
  );
  expect(boxes, isNotEmpty, reason: 'link "$pattern" must be laid out');
  await tester.tapAt(render.localToGlobal(boxes.first.toRect().center));
}

Future<GoRouter> pumpArticle(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  String html = _articleHtml,
  Map<String, http.Response> images = const {},
  List<Override> extraOverrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/recommended',
    routes: [
      GoRoute(
        path: '/recommended',
        builder: (_, _) => const SpotlightArticlePage(articleId: 101),
      ),
      GoRoute(
        path: '/recommended/illust/:illustId',
        builder: (_, state) =>
            Scaffold(body: Text('illust ${state.pathParameters['illustId']}')),
      ),
      GoRoute(
        path: '/recommended/user/:userId',
        builder: (_, state) =>
            Scaffold(body: Text('user ${state.pathParameters['userId']}')),
      ),
    ],
  );
  addTearDown(router.dispose);

  final webClient = MockClient(
    (request) async =>
        images['${request.url}'] ??
        http.Response.bytes(
          utf8.encode(html),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
  );
  final (container, _) = await makeSpotlightWorld(webClient: webClient);
  addTearDown(container.dispose);

  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        // A nested scope carries test-only overrides (e.g. the share
        // boundary) without rebuilding the fixture container.
        child: ProviderScope(
          overrides: extraOverrides,
          child: MaterialApp.router(
            builder: promptHostBuilder,
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
  return router;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    // Images on the page start the network policy's connectivity watch;
    // unanswered, its replies land in whichever later test runs real async.
    answerConnectivityChannels();
  });

  group('parseSpotlightArticle', () {
    test('parses title, description, paragraph links, heading and card', () {
      final body = parseSpotlightArticle(_articleHtml);

      expect(body.title, '特辑标题');
      expect(body.description, contains('文章描述文本'));
      expect(body.blocks, hasLength(4));

      final paragraph = body.blocks[0] as SpotlightParagraph;
      expect(paragraph.segments[1].text, '作品链接');
      expect(
        paragraph.segments[1].href,
        'https://www.pixiv.net/artworks/12345',
      );
      expect(paragraph.segments[0].href, isNull);

      final heading = body.blocks[1] as SpotlightHeading;
      expect(heading.text, '小节标题');
      expect(heading.level, 2);

      final image = body.blocks[2] as SpotlightImage;
      expect(image.url, 'https://i.pximg.net/c/600x600/spotlight/x.jpg');

      final card = body.blocks[3] as SpotlightIllustCard;
      expect(card.illustId, 777);
      expect(card.title, '作品标题');
      expect(card.userName, '作者名');
      expect(card.userId, 42);
      expect(card.imageUrl, 'https://i.pximg.net/t/777.jpg');
      expect(card.userAvatarUrl, 'https://i.pximg.net/user-profile/42.jpg');
    });

    test('reads work cards from a real pixivision article', () {
      final body = parseSpotlightArticle(
        File('test/fixtures/pixivision/article_10943.html').readAsStringSync(),
      );

      expect(body.title, '轻盈步伐 - 凉鞋插画特辑 -');
      // The header holds category, date, title and tags — no lead text.
      expect(body.description, isNull);
      final cards = body.blocks.whereType<SpotlightIllustCard>().toList();
      expect(cards, hasLength(2));
      final first = cards.first;
      expect(first.illustId, 117332546);
      expect(first.title, '休假');
      expect(first.userName, '茶壶泡泡');
      expect(first.userId, 80088127);
      // The avatar comes first in the card: the work image is the one
      // inside the artwork link, not the first image.
      expect(
        first.imageUrl,
        'https://i.pximg.net/c/768x1200_80/img-master/img/2024/03/28/21/51/'
        '58/117332546_p0_master1200.jpg',
      );
      expect(first.userAvatarUrl, contains('/user-profile/'));
      // Card parts never leak out as loose headings, paragraphs or images.
      expect(body.blocks.whereType<SpotlightHeading>(), isEmpty);
      expect(
        body.blocks.whereType<SpotlightImage>().map((image) => image.url),
        ['https://embed.pixiv.net/pixivision/zh/a/10943/ogimage.jpg'],
      );
    });

    test('descends into the _feature body variant', () {
      final body = parseSpotlightArticle(_featureHtml);

      expect(body.title, 'feature 特辑');
      expect(body.blocks, hasLength(3));
      expect(body.blocks[0], isA<SpotlightParagraph>());
      expect((body.blocks[1] as SpotlightHeading).level, 3);
      expect(
        (body.blocks[2] as SpotlightImage).url,
        'https://s.pximg.net/spotlight/y.jpg',
      );
    });

    test('missing article or empty body raises ApiParseError', () {
      expect(
        () => parseSpotlightArticle('<html><body><p>none</p></body></html>'),
        throwsA(isA<ApiParseError>()),
      );
      expect(
        () => parseSpotlightArticle(
          '<html><body><article><p>no body</p></article></body></html>',
        ),
        throwsA(isA<ApiParseError>()),
      );
      expect(
        () => parseSpotlightArticle(
          '<html><body><article><div class="am__body"></div></article>'
          '</body></html>',
        ),
        throwsA(isA<ApiParseError>()),
      );
    });
  });

  group('PixivSpotlightRepository.fetchArticleHtml', () {
    test('sends desktop UA, pixivision referer and app language', () async {
      final requests = <http.Request>[];
      final webClient = MockClient((request) async {
        requests.add(request);
        return http.Response('<article></article>', 200);
      });
      final (container, _) = await makeSpotlightWorld(webClient: webClient);
      addTearDown(container.dispose);

      final html = await container
          .read(spotlightRepositoryProvider)
          .fetchArticleHtml(
            'https://www.pixivision.net/a/101',
            languageTag: 'ja-JP',
          );

      expect(html, '<article></article>');
      expect(requests.single.url.host, 'www.pixivision.net');
      expect(requests.single.headers['User-Agent'], contains('Mozilla/5.0'));
      expect(requests.single.headers['Referer'], 'https://www.pixivision.net/');
      expect(requests.single.headers['Accept-Language'], 'ja-JP');
    });

    test('rejects non-pixivision urls before requesting', () async {
      var requested = false;
      final webClient = MockClient((request) async {
        requested = true;
        return http.Response('', 200);
      });
      final (container, _) = await makeSpotlightWorld(webClient: webClient);
      addTearDown(container.dispose);

      expect(
        () => container
            .read(spotlightRepositoryProvider)
            .fetchArticleHtml('https://evil.example.com/a/1'),
        throwsA(isA<ApiParseError>()),
      );
      expect(requested, isFalse);
    });
  });

  test('article body provider fetches and parses', () async {
    final webClient = MockClient(
      (request) async => http.Response.bytes(
        utf8.encode(_articleHtml),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    final (container, _) = await makeSpotlightWorld(webClient: webClient);
    addTearDown(container.dispose);

    const key = (id: 101, url: 'https://www.pixivision.net/a/101');
    // autoDispose: an active listener keeps the provider alive while the
    // future resolves — a bare read() subscription closes immediately.
    final sub = container.listen(spotlightArticleBodyProvider(key), (_, _) {});
    addTearDown(sub.close);
    final body = await container.read(spotlightArticleBodyProvider(key).future);
    expect(body.title, '特辑标题');
    expect(body.blocks, hasLength(4));
  });

  testWidgets('article page renders blocks and routes artwork links', (
    tester,
  ) async {
    final webClient = MockClient(
      (request) async => http.Response.bytes(
        utf8.encode(_articleHtml),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    final (container, _) = await makeSpotlightWorld(webClient: webClient);
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/recommended',
      routes: [
        GoRoute(
          path: '/recommended',
          builder: (_, _) => const SpotlightArticlePage(articleId: 101),
        ),
        GoRoute(
          path: '/recommended/illust/:illustId',
          builder: (_, state) => Scaffold(
            body: Text('illust ${state.pathParameters['illustId']}'),
          ),
        ),
        GoRoute(
          path: '/recommended/user/:userId',
          builder: (_, state) =>
              Scaffold(body: Text('user ${state.pathParameters['userId']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            builder: promptHostBuilder,
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('特辑标题'), findsOneWidget);
      expect(find.text('小节标题'), findsOneWidget);
      expect(find.text('作品标题'), findsOneWidget);

      await tapSelectableLink(tester, '作品链接');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended/illust/12345');
    });
  });

  group('a pixivision CDN image', () {
    // Not a pximg host: plain third-party traffic, no Pixiv referer chain.
    const cdn = 'https://embed.pixiv.net/pixivision/zh/a/101/ogimage.jpg';
    const html =
        '<article><header><h1 class="am__title">特辑标题</h1></header>'
        '<div class="am__body"><p><img src="$cdn"></p></div></article>';

    bool painted(WidgetTester tester) => tester
        .widgetList<RawImage>(find.byType(RawImage))
        .any((image) => image.image != null);

    testWidgets('loads through the third-party client', (tester) async {
      await pumpArticle(
        tester,
        html: html,
        images: {cdn: http.Response.bytes(onePixelPng, 200)},
      );
      await pumpIoUntil(tester, () => painted(tester));
      expect(find.byIcon(Icons.broken_image), findsNothing);
    });

    testWidgets('shows a broken image when the CDN fails', (tester) async {
      await pumpArticle(
        tester,
        html: html,
        images: {cdn: http.Response('', 404)},
      );
      await pumpIoUntil(
        tester,
        () => find.byIcon(Icons.broken_image).evaluate().isNotEmpty,
      );
      expect(painted(tester), isFalse);
    });
  });

  group('article layout and selection', () {
    testWidgets('body blocks render as SelectableText', (tester) async {
      await pumpArticle(tester);

      // Title, description, heading and paragraphs are selectable per
      // block; the illust card stays plain text (it is a navigation tile).
      expect(find.byType(SelectableText), findsWidgets);
      expect(find.widgetWithText(SelectableText, '特辑标题'), findsOneWidget);
      expect(find.widgetWithText(SelectableText, '小节标题'), findsOneWidget);
      expect(find.widgetWithText(SelectableText, '作品标题'), findsNothing);
      expect(find.text('作品标题'), findsOneWidget);
      expect(find.byType(SelectionArea), findsNothing);
    });

    for (final width in const [840.0, 1200.0]) {
      testWidgets('body column is capped and centered at ${width}dp', (
        tester,
      ) async {
        await pumpArticle(tester, size: Size(width, 800));

        final list = tester.getRect(find.byType(ListView));
        expect(list.width, lessThanOrEqualTo(700));
        expect(list.left, greaterThan(0));
        expect(list.center.dx, closeTo(width / 2, 0.5));
      });
    }

    testWidgets('paragraph artwork links still route natively', (tester) async {
      final router = await pumpArticle(tester);
      await tapSelectableLink(tester, '作品链接');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended/illust/12345');
    });
  });

  group('article work cards', () {
    Finder workImage(String title) => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == title,
    );

    testWidgets('a work is a full-width image that opens the artwork', (
      tester,
    ) async {
      final router = await pumpArticle(tester);
      final image = workImage('作品标题');
      await tester.ensureVisible(image);
      await tester.pumpAndSettle();

      final list = tester.getRect(find.byType(ListView));
      expect(
        tester.getRect(image).width,
        closeTo(list.width - 2 * FuncSpacing.lg, 0.5),
      );
      expect(
        tester.getSemantics(image),
        isSemantics(isButton: true, hasTapAction: true, label: '作品标题'),
      );
      // No card frame or trailing arrow around the work any more.
      expect(find.byType(Card), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);

      await tester.tap(image);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended/illust/777');
    });

    testWidgets('the author row opens the author', (tester) async {
      final router = await pumpArticle(tester);
      await tester.ensureVisible(find.text('作者名'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('作者名'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended/user/42');
    });

    testWidgets('an author without a user id is plain text', (tester) async {
      const html = '''
<html><body><article><header><h1>t</h1></header><div class="am__body">
  <div class="am__work">
    <h3><a href="/artworks/778">无作者链接</a></h3>
    <p class="am__work__user-name">by <a href="https://example.com/">外部作者</a></p>
    <a href="/artworks/778"><img src="https://i.pximg.net/t/778.jpg"></a>
  </div>
</div></article></body></html>
''';
      await pumpArticle(tester, html: html);

      expect(find.text('外部作者'), findsOneWidget);
      expect(find.byType(AuthorRow), findsNothing);
      expect(
        tester.getSemantics(find.text('外部作者')),
        isNot(isSemantics(isButton: true)),
      );
    });
  });

  group('article actions', () {
    testWidgets('share hands the canonical payload to the share service', (
      tester,
    ) async {
      final share = _RecordingShareService()
        ..outcome = ShareOutcome.copiedToClipboard;
      await pumpArticle(
        tester,
        extraOverrides: [shareServiceProvider.overrideWithValue(share)],
      );

      await tester.tap(find.byTooltip('分享'));
      await tester.pumpAndSettle();

      final payload = share.lastPayload;
      expect(payload, isNotNull);
      expect(payload!.url, 'https://www.pixivision.net/a/101');
      expect(payload.author, 'pixivision');
      // No feed entry is seeded, so the title resolves to the page title.
      expect(payload.title, '特辑');
      // The clipboard fallback is surfaced, never silent.
      expect(find.text('链接已复制'), findsOneWidget);
    });

    testWidgets('open-in-browser launches the canonical url externally', (
      tester,
    ) async {
      final launched = mockUrlLauncher(tester);

      await pumpArticle(tester);
      await tester.tap(find.byTooltip('在浏览器打开'));
      await tester.pumpAndSettle();

      expect(launched, ['https://www.pixivision.net/a/101']);
    });
  });
}
