import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/spotlight/article_parser.dart';
import 'package:pixiv_func/core/spotlight/spotlight_article_controller.dart';
import 'package:pixiv_func/core/spotlight/spotlight_models.dart';
import 'package:pixiv_func/core/spotlight/spotlight_repository.dart';
import 'package:pixiv_func/features/spotlight/spotlight_article_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/spotlight_world.dart';
import 'helpers/test_preferences.dart';

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
    <div class="illust">
      <a href="/artworks/777"><img src="https://i.pximg.net/t/777.jpg"></a>
      <h3>作品标题</h3>
      <p><a href="/users/42">作者名</a></p>
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

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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

  group('article layout and selection', () {
    Future<GoRouter> pumpArticle(
      WidgetTester tester, {
      Size size = const Size(390, 844),
      String html = _articleHtml,
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

      final webClient = MockClient(
        (request) async => http.Response.bytes(
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
}
