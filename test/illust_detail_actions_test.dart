import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:flutter/services.dart';

import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/app/layout/two_pane.dart';
import 'package:parfait/core/bookmark/bookmark_tag_providers.dart';
import 'package:parfait/core/comments/comment_assets.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_image_pager.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/comment_composer.dart';
import 'package:parfait/app/widgets/comment_text.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_page_counter.dart';
import 'package:parfait/features/illust/detail/widgets/detail_section_header.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/search/tag_search_page.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/share/share_service.dart';

import 'helpers/detail_world.dart';
import 'helpers/download_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/settings_world.dart' show RecordingTranslationEngine;
import 'helpers/view_size.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/illust_detail_page_support.dart';

/// A phone short enough that the sections under the info block start
/// below the fold.
const _short = Size(390, 560);

void main() {
  // The detail page tracks the visible image page through
  // VisibilityDetector (compact-header page counter); a zero interval
  // defers updates to post-frame callbacks so no Timer outlives a test.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  group('floating action bar (E2)', () {
    Finder inBar(Finder finder) =>
        find.descendant(of: find.byType(DetailActionBar), matching: finder);

    Rect toolbarRect(WidgetTester tester) =>
        tester.getRect(inBar(find.byType(Material)).first);

    testWidgets('bottom inset and margin both clear the gesture area', (
      tester,
    ) async {
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);

      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();

      expect(
        toolbarRect(tester).bottom,
        closeTo(844 - 24 - DetailActionBar.margin, 0.5),
      );
    });

    testWidgets('the action bar follows a drag and settles at the nearer end', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();
      final shownTop = toolbarRect(tester).top;
      double moved() => toolbarRect(tester).top - shownTop;
      final page = tester.getCenter(find.byType(IllustDetailPage));

      final short = await tester.startGesture(page);
      await short.moveBy(const Offset(0, -20));
      await tester.pump();
      final start = moved();
      await short.moveBy(const Offset(0, -10));
      await tester.pump();
      expect(moved() - start, closeTo(10, 0.01));
      await short.up();
      await tester.pumpAndSettle();
      expect(moved(), closeTo(0, 0.5));

      final far = await tester.startGesture(page);
      await far.moveBy(const Offset(0, -20));
      await tester.pump();
      await far.moveBy(const Offset(0, -DetailActionBar.height));
      await tester.pump();
      await far.up();
      await tester.pumpAndSettle();
      expect(inBar(find.byType(Material)).hitTestable(), findsNothing);
    });

    testWidgets('download shows the ring, then the saved state; its prompt '
        'rests above the bar', (tester) async {
      final (container, transport, _) = await makeWorld(
        scriptedResponses: 0,
        // Every chunk reports, so the ring is checkable mid-download.
        progressThrottle: Duration.zero,
      );
      final gates = [Completer<void>(), Completer<void>()];
      for (var i = 0; i < 2; i++) {
        transport.responses.add(
          ScriptedResponse(
            contentLength: 2,
            chunks: const [
              [1],
              [2],
            ],
            completers: [gates[0], gates[1]],
          ),
        );
      }
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();

      await tester.tap(inBar(find.byTooltip('下载全部')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(inBar(find.byTooltip('下载中')), findsOneWidget);
      expect(inBar(find.byType(CircularProgressIndicator)), findsOneWidget);
      // The prompt sits above the bar, not over it.
      final prompt = find.text('已加入下载队列');
      expect(prompt, findsOneWidget);
      expect(
        tester.getRect(prompt).bottom,
        lessThanOrEqualTo(toolbarRect(tester).top),
      );

      // Half of each page's bytes: half the work.
      gates[0].complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final ring = tester.widget<CircularProgressIndicator>(
        inBar(find.byType(CircularProgressIndicator)),
      );
      expect(ring.value, closeTo(0.5, 0.01));

      gates[1].complete();
      await tester.pumpAndSettle();
      expect(inBar(find.byIcon(Icons.download_done)), findsOneWidget);
      expect(inBar(find.byTooltip('已下载')), findsOneWidget);
    });

    testWidgets('slides away reading down, returns reading up, and stays '
        'while TalkBack explores', (tester) async {
      // A touch device: the desktop host starts the list in wheel mode,
      // where a drag does not scroll.
      PlatformCaps.debugSystemOverride = const PlatformCaps(isAndroid: true);
      addTearDown(() => PlatformCaps.debugSystemOverride = null);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();
      final screen = tester.getSize(find.byType(IllustDetailPage));
      final rest = toolbarRect(tester);
      final scroll = find.bySubtype<CustomScrollView>();

      await tester.drag(scroll, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(toolbarRect(tester).top, greaterThanOrEqualTo(screen.height));

      await tester.drag(scroll, const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(toolbarRect(tester), rest);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(toolbarRect(tester), rest);
    });

    testWidgets('a page whose last strip sits behind the top bar no longer '
        'shows the count', (tester) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        surface: _short,
      );
      await tester.pumpAndSettle();
      final pageHeight = tester
          .getSize(find.byType(DetailPageImage).first)
          .height;
      final topChrome = tester.getBottomLeft(find.byType(AppTopBar)).dy;
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      Future<void> scrollTo(double offset) async {
        position.jumpTo(offset);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
      }

      // Its end still below the bar: on screen, counted.
      await scrollTo(pageHeight - topChrome - 40);
      expect(find.byType(PageCountPill), findsOneWidget);
      // Only a strip behind the bar is left: gone, not hanging over the
      // info below.
      await scrollTo(pageHeight - topChrome + 20);
      expect(find.byType(PageCountPill), findsNothing);
    });
  });

  group('comment preview and author works (§2-E)', () {
    /// Brings a section header mid-screen and lets its request land.
    Future<void> showSection(WidgetTester tester, Finder header) async {
      await mockNetworkImagesFor(() async {
        await tester.scrollUntilVisible(
          header,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(tester.element(header), alignment: 0.3);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
      });
    }

    Map<String, dynamic> comment(int id) => {
      'id': id,
      'comment': 'comment $id',
      'date': '2026-08-27T10:00:00+09:00',
      'user': {
        'id': 10 + id,
        'name': 'user $id',
        'account': 'user_$id',
        'profile_image_urls': <String, String>{},
      },
      'has_replies': false,
    };

    testWidgets('neither asks for data before it is on screen', (tester) async {
      final log = <String>[];
      final (container, _, _) = await makeWorld(requestLog: log);
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        surface: _short,
      );
      await tester.pumpAndSettle();
      expect(log, isNot(contains('/v3/illust/comments')));
      expect(log, isNot(contains('/v1/user/illusts')));

      await showSection(tester, find.text('作者的其他作品'));
      expect(log.where((path) => path == '/v3/illust/comments'), hasLength(1));
      expect(log.where((path) => path == '/v1/user/illusts'), hasLength(1));
      // No comments yet: the entry asks for the first.
      expect(find.text('留下第一条评论'), findsOneWidget);
    });

    testWidgets(
      'the entry composes in place; a sent comment heads the preview',
      (tester) async {
        final (container, _, _) = await makeWorld(
          commentOverrides: {
            42: [comment(1)],
          },
        );
        // Under TalkBack, where the bar never slides away on its own.
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
        await tester.pumpAndSettle();
        await showSection(tester, find.text('评论（1）'));
        final entry = find.byKey(const Key('illust-comment-entry'));
        double bar() => tester
            .widget<DetailActionBar>(find.byType(DetailActionBar))
            .visibility
            .value;
        CommentComposerState composer() =>
            tester.state<CommentComposerState>(find.byType(CommentComposer));
        // The composer goes a frame after what it stood on is down.
        Future<void> settle() async {
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
        }

        await mockNetworkImagesFor(() async {
          // The stamp key opens on the stamp panel, in place of the bar.
          await tester.tap(
            find.descendant(of: entry, matching: find.byTooltip('Stamp')),
          );
          await settle();
          expect(composer().debugInputState, CommentComposerInputState.stamp);
          expect(bar(), 0);
          // Back closes the composer, not the page.
          await tester.binding.handlePopRoute();
          await settle();
          expect(find.byType(CommentComposer), findsNothing);
          expect(find.byType(IllustDetailPage), findsOneWidget);
          expect(bar(), 1);

          // On the keyboard the composer rides it: out of sight before it
          // rises, whole over its upper half, and gone with it when it is
          // put away on its own.
          double shown() => tester
              .widget<Opacity>(
                find
                    .descendant(
                      of: find.byType(CommentComposer),
                      matching: find.byType(Opacity),
                    )
                    .first,
              )
              .opacity;
          void keyboardAt(double height) => tester.view.viewInsets =
              FakeViewPadding(bottom: height * tester.view.devicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          await tester.tap(
            find.descendant(of: entry, matching: find.text('添加评论')),
          );
          await tester.pump();
          await tester.pump();
          expect(
            composer().debugInputState,
            CommentComposerInputState.keyboard,
          );
          expect(shown(), 0);
          keyboardAt(300);
          await tester.pump();
          expect(shown(), 1);
          keyboardAt(60);
          await tester.pump();
          expect(shown(), inExclusiveRange(0, 1));
          keyboardAt(0);
          // Down, out of focus, then gone: a frame each.
          await tester.pump();
          await tester.pump();
          await settle();
          expect(find.byType(CommentComposer), findsNothing);
          expect(bar(), 1);

          // Text left by a touch beside the composer is there the next
          // time. With no keyboard rising, the composer shows anyway.
          await tester.tap(
            find.descendant(of: entry, matching: find.text('添加评论')),
          );
          await settle();
          expect(shown(), 1);
          await tester.enterText(find.byType(TextField), 'hello');
          // An emoji inserted last is part of it too.
          await tester.tap(find.byTooltip('Emoji'));
          await settle();
          await tester.tap(
            find
                .descendant(
                  of: find.byType(CommentComposer),
                  matching: find.byType(InkResponse),
                )
                .first,
          );
          final draft = 'hello(${commentEmojiNames.first})';
          // The page stays live: a drag on it closes the composer and
          // scrolls on.
          final page = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          final before = page.pixels;
          await tester.dragFrom(const Offset(200, 200), const Offset(0, 80));
          await settle();
          expect(find.byType(CommentComposer), findsNothing);
          expect(page.pixels, lessThan(before));
          await tester.dragFrom(const Offset(200, 200), const Offset(0, -80));
          await settle();
          await tester.tap(
            find.descendant(of: entry, matching: find.text('添加评论')),
          );
          await settle();
          expect(find.text(draft), findsOneWidget);

          await tester.tap(find.byIcon(Icons.send_outlined));
          await settle();
        });
        expect(find.byType(CommentComposer), findsNothing);
        final rows = find.descendant(
          of: find.byKey(const Key('illust-comments-preview')),
          matching: find.byType(CommentText),
        );
        expect(
          tester.widget<CommentText>(rows.first).text,
          'hello(${commentEmojiNames.first})',
        );
        expect(find.text('评论（2）'), findsOneWidget);
      },
    );

    testWidgets('the preview shows the first three comments under a heading; '
        'See all opens the comments page', (tester) async {
      final (container, _, _) = await makeWorld(
        commentOverrides: {
          42: [for (var i = 1; i <= 5; i++) comment(i)],
        },
      );
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        useRouter: true,
      );
      await tester.pumpAndSettle();
      await showSection(
        tester,
        find.widgetWithText(DetailSectionHeader, '评论（5）'),
      );

      final preview = find.byKey(const Key('illust-comments-preview'));
      for (var i = 1; i <= 3; i++) {
        expect(
          find.descendant(of: preview, matching: find.text('comment $i')),
          findsOneWidget,
        );
      }
      expect(find.text('comment 4'), findsNothing);
      final heading = find.ancestor(
        of: find.text('评论（5）'),
        matching: find.byType(DetailSectionHeader),
      );
      expect(
        tester.getSemantics(
          find.descendant(of: heading, matching: find.text('评论（5）')),
        ),
        isSemantics(label: '评论（5）', isHeader: true),
      );

      await mockNetworkImagesFor(() async {
        await tester.tap(
          find.descendant(of: heading, matching: find.text('查看全部')),
        );
        await tester.pumpAndSettle();
      });
      expect(find.byType(CommentsPage), findsOneWidget);
    });

    testWidgets('a work with comments off asks for none and says so', (
      tester,
    ) async {
      final log = <String>[];
      final (container, _, _) = await makeWorld(
        requestLog: log,
        detailOverrides: {
          42: {...illustJson(42), 'comment_access_control': 1},
        },
      );
      // The detail lands while the section is still below the fold.
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        surface: _short,
      );
      await tester.pumpAndSettle();
      await showSection(tester, find.text('作者的其他作品'));
      final closed = find.byKey(const Key('illust-comments-closed'));
      expect(find.text('作者已关闭评论'), findsOneWidget);
      expect(
        find.descendant(of: closed, matching: find.text('查看全部')),
        findsNothing,
      );
      expect(log, isNot(contains('/v3/illust/comments')));
    });

    testWidgets('the author strip leaves this work and muted ones out and '
        'opens the others', (tester) async {
      final (container, _, _) = await makeWorld(
        mutedTags: {'muted'},
        authorWorksOverrides: {
          99: [
            for (final id in [42, 501, 502]) illustJson(id),
            {
              ...illustJson(503),
              'tags': [
                {'name': 'muted'},
              ],
            },
          ],
        },
      );
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        useRouter: true,
      );
      await tester.pumpAndSettle();
      await showSection(tester, find.text('作者的其他作品'));

      final strip = find.byKey(const Key('illust-author-works'));
      Finder tile(String title) =>
          find.descendant(of: strip, matching: find.bySemanticsLabel(title));
      expect(tile('illust 501'), findsOneWidget);
      expect(tile('illust 502'), findsOneWidget);
      expect(tile('illust 42'), findsNothing);
      expect(tile('illust 503'), findsNothing, reason: 'muted (A6)');

      await mockNetworkImagesFor(() async {
        await tester.tap(tile('illust 501'));
        await tester.pumpAndSettle();
      });
      expect(
        find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 501,
        ),
        findsOneWidget,
      );
    });
  });

  group('detail overflow menu (R3)', () {
    testWidgets('download-all and the heart stay one tap away while share '
        'and selection move into the ⋮ menu', (tester) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);

      expect(find.byTooltip('Download All'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_outline_sharp), findsOneWidget);
      expect(find.byTooltip('Show menu'), findsOneWidget);
      expect(find.byTooltip('Share'), findsNothing);
      expect(find.byTooltip('Select pages to download'), findsNothing);
    });

    testWidgets('share goes through the ⋮ menu to the share boundary', (
      tester,
    ) async {
      final share = RecordingShareService();
      final (container, _, _) = await makeWorld(
        extraOverrides: [shareServiceProvider.overrideWithValue(share)],
      );
      await pumpDetail(tester, container);

      await openDetailMenu(tester);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      expect(share.payloads, hasLength(1));
      expect(share.payloads.single.url, 'https://www.pixiv.net/artworks/42');
    });

    testWidgets('the ⋮ menu carries the long-press actions too', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        extraOverrides: [
          userBookmarkTagSuggestionsProvider.overrideWith(
            (ref, _) async => const [],
          ),
        ],
      );
      await pumpDetail(tester, container);

      await openDetailMenu(tester);
      expect(find.text('Watch later'), findsOneWidget);
      expect(find.text('Mute author'), findsOneWidget);
      await tester.tap(find.text('Mute this work'));
      await tester.pumpAndSettle();
      expect(container.read(muteStoreProvider).isWorkMuted(42), isTrue);
      expect(find.text('Muted'), findsOneWidget);

      await openDetailMenu(tester);
      expect(find.text('Unmute this work'), findsOneWidget);
      await tester.tap(find.text('Bookmark illustration'));
      await tester.pumpAndSettle();
      // The heart's long-press sheet, titled as the menu entry was.
      expect(find.text('Bookmark illustration'), findsOneWidget);
    });

    testWidgets('a long six-page work still reaches InfoBlock via the menu', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(
            42,
            pageCount: 6,
            type: 'manga',
            withMetaPages: true,
            caption: '作品说明文字',
          ),
        },
      );
      container.read(illustStoreProvider).mergeAll([
        parseIllust(
          illustJson(
            42,
            pageCount: 6,
            type: 'manga',
            withMetaPages: true,
            caption: '作品说明文字',
          ),
        ),
      ]);
      await pumpDetail(
        tester,
        container,
        seedStore: false,
        locale: const Locale('zh', 'CN'),
      );
      await tester.pumpAndSettle();

      // Six image pages push the InfoBlock past the cache extent — its
      // caption is not built yet.
      expect(find.text('作品说明文字'), findsNothing);

      await openDetailMenu(tester, tooltip: '显示菜单');
      await tester.tap(find.text('跳到作品信息区'));
      await tester.pumpAndSettle();

      expect(find.text('作品说明文字'), findsOneWidget);
      expect(
        tester.getRect(find.text('作品说明文字')).top,
        lessThan(tester.view.physicalSize.height),
      );
    });
  });

  group('tag action menu (R3)', () {
    /// The tag row sits below the image slivers — scroll it into view
    /// before the long-press (finders cannot reach unbuilt sliver
    /// children). The predicate finder stays single-valued ('original' is
    /// the fixture's first tag) without `.first`, which would throw while
    /// the row is still unbuilt mid-scroll.
    Finder originalTagChip() =>
        find.byWidgetPredicate((w) => w is TagChip && w.label == 'original');

    Future<void> longPressFirstTag(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        originalTagChip(),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.longPress(originalTagChip());
      await tester.pumpAndSettle();
    }

    void mockClipboard(
      List<String> captured,
      TestWidgetsFlutterBinding binding,
    ) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            captured.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    testWidgets('translate answers inside the menu, or points to settings '
        'while translation is off', (tester) async {
      var provider = TranslationProvider.disabled;
      final engine = RecordingTranslationEngine((_) => 'TAG-IN-ZH');
      final (container, _, _) = await makeWorld(
        extraOverrides: [
          translationServiceProvider.overrideWithValue(
            ConfiguredTranslationService(
              resolveProvider: () => provider,
              google: engine,
              baidu: engine,
              llm: engine,
              doubao: engine,
            ),
          ),
        ],
      );
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await longPressFirstTag(tester);

      await tester.tap(find.text('翻译标签名'));
      await tester.pumpAndSettle();
      expect(find.text('去设置'), findsOneWidget);
      // Off is not an error, and there is nothing to hide: the row keeps
      // its name and the next tap asks again.
      final rowIcon = find.descendant(
        of: find.widgetWithText(ListTile, '翻译标签名'),
        matching: find.byIcon(Icons.translate),
      );
      expect(tester.widget<Icon>(rowIcon).color, isNull);

      provider = TranslationProvider.google;
      await tester.tap(find.text('翻译标签名'));
      await tester.pumpAndSettle();
      expect(find.text('TAG-IN-ZH'), findsOneWidget);
      expect(find.text('收起翻译'), findsOneWidget);
      expect(engine.sources, ['original']);
    });

    testWidgets(
      'long-press opens the menu with search/copy/mute/batch entries and '
      'copy lands on the clipboard',
      (tester) async {
        final (container, _, _) = await makeWorld();
        final captured = <String>[];
        mockClipboard(captured, tester.binding);
        await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

        await longPressFirstTag(tester);
        expect(find.text('搜索该标签'), findsOneWidget);
        expect(find.text('复制标签名'), findsOneWidget);
        expect(find.text('屏蔽该标签'), findsOneWidget);
        expect(find.text('批量屏蔽标签'), findsOneWidget);

        await tester.tap(find.text('复制标签名'));
        await tester.pumpAndSettle();
        expect(captured, ['original']);
        expect(find.text('已复制标签'), findsOneWidget);
      },
    );

    testWidgets('mute writes MuteStore.tags and a muted tag offers 解除屏蔽', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

      // Mute: the menu item writes through the real MuteStore (the
      // mock client answers /v1/mute/edit with 200).
      await longPressFirstTag(tester);
      await tester.tap(find.text('屏蔽该标签'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(muteStoreProvider).tags, contains('original'));

      // The same long-press on a muted tag names the action 解除屏蔽.
      await longPressFirstTag(tester);
      expect(find.text('解除屏蔽该标签'), findsOneWidget);
      await tester.tap(find.text('解除屏蔽该标签'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        container.read(muteStoreProvider).tags,
        isNot(contains('original')),
      );
    });

    testWidgets(
      'the batch entry flips block mode and search opens the tag feed',
      (tester) async {
        final (container, _, _) = await makeWorld();
        await pumpDetail(
          tester,
          container,
          locale: const Locale('zh', 'CN'),
          useRouter: true,
        );

        // 批量屏蔽标签 → chips enter block mode.
        await longPressFirstTag(tester);
        await tester.tap(find.text('批量屏蔽标签'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TagChip>(find.byType(TagChip).first).blockMode,
          isTrue,
        );

        // 搜索该标签 → pushes the tag feed route over the detail page.
        await longPressFirstTag(tester);
        await tester.tap(find.text('搜索该标签'));
        await tester.pumpAndSettle();
        expect(find.byType(TagSearchPage), findsOneWidget);
      },
    );
  });

  group('two-pane layout (landscape, medium and wider)', () {
    testWidgets('splits into image pager and meta column', (tester) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, surface: const Size(1400, 900));
      expect(find.byType(TwoPane), findsOneWidget);
      expect(find.byType(DetailImagePager), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);
      // The shared page-counter overlay and the meta column's info block
      // both render.
      expect(find.byType(DetailPageCounter), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('作品说明文字'), findsOneWidget);
      // The action bar stays inside the meta column, clear of the divider.
      final divider = tester.getRect(
        find.descendant(
          of: find.byType(TwoPane),
          matching: find.byType(VerticalDivider),
        ),
      );
      expect(
        tester.getRect(find.byType(DetailActionBar)).left,
        greaterThanOrEqualTo(divider.right),
      );
    });

    testWidgets('arrow keys page the image pane; a resize keeps the page', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, surface: const Size(1400, 900));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('2 / 2'), findsOneWidget);
      // A dragged window or a folding tablet: still two panes, same page.
      setViewSize(tester, const Size(1000, 640));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1 / 2'), findsOneWidget);
    });
  });
}
