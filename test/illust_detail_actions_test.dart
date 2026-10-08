import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:flutter/services.dart';

import 'package:parfait/app/layout/two_pane.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_image_pager.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_page_counter.dart';
import 'package:parfait/features/illust/detail/widgets/detail_section_header.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/search/tag_search_page.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/detail_world.dart';
import 'helpers/download_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/illust_detail_page_support.dart';

void main() {
  installMemoryPreferences();

  // The detail page tracks the visible image page through
  // VisibilityDetector (compact-header page counter); a zero interval
  // defers updates to post-frame callbacks so no Timer outlives a test.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  group('floating action bar (E2)', () {
    Finder inBar(Finder finder) =>
        find.descendant(of: find.byType(DetailActionBar), matching: finder);

    Rect toolbarRect(WidgetTester tester) =>
        tester.getRect(inBar(find.byType(Material)).first);

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
      final scroll = find.byType(CustomScrollView);

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
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
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
    Future<void> showSection(WidgetTester tester, String title) async {
      await mockNetworkImagesFor(() async {
        await tester.scrollUntilVisible(
          find.text(title),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text(title)),
          alignment: 0.3,
        );
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
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();
      expect(log, isNot(contains('/v3/illust/comments')));
      expect(log, isNot(contains('/v1/user/illusts')));

      await showSection(tester, '作者的其他作品');
      expect(log.where((path) => path == '/v3/illust/comments'), hasLength(1));
      expect(log.where((path) => path == '/v1/user/illusts'), hasLength(1));
    });

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
      await showSection(tester, '查看全部');

      final preview = find.byKey(const Key('illust-comments-preview'));
      for (var i = 1; i <= 3; i++) {
        expect(
          find.descendant(of: preview, matching: find.text('comment $i')),
          findsOneWidget,
        );
      }
      expect(find.text('comment 4'), findsNothing);
      final heading = find.ancestor(
        of: find.text('评论'),
        matching: find.byType(DetailSectionHeader),
      );
      expect(
        tester.getSemantics(
          find.descendant(of: heading, matching: find.text('评论')),
        ),
        isSemantics(label: '评论', isHeader: true),
      );

      await mockNetworkImagesFor(() async {
        await tester.tap(
          find.descendant(of: heading, matching: find.text('查看全部')),
        );
        await tester.pumpAndSettle();
      });
      expect(find.byType(CommentsPage), findsOneWidget);
    });

    testWidgets('the author strip leaves this work out and opens the others', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        authorWorksOverrides: {
          99: [illustJson(42), illustJson(501), illustJson(502)],
        },
      );
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        useRouter: true,
      );
      await tester.pumpAndSettle();
      await showSection(tester, '作者的其他作品');

      final strip = find.byKey(const Key('illust-author-works'));
      Finder tile(String title) =>
          find.descendant(of: strip, matching: find.bySemanticsLabel(title));
      expect(tile('illust 501'), findsOneWidget);
      expect(tile('illust 502'), findsOneWidget);
      expect(tile('illust 42'), findsNothing);

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

    testWidgets('the menu artwork-info item scrolls InfoBlock into view', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();

      // InfoBlock's caption sits below the fold — not built yet.
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

    testWidgets('a long six-page work still reaches InfoBlock via the menu', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(
            42,
            pageCount: 6,
            withMetaPages: true,
            caption: '作品说明文字',
          ),
        },
      );
      container.read(illustStoreProvider).mergeAll([
        parseIllust(
          illustJson(42, pageCount: 6, withMetaPages: true, caption: '作品说明文字'),
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

  group('two-pane layout (width >= 1200)', () {
    testWidgets('splits into image pager and meta column', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);
      expect(find.byType(TwoPane), findsOneWidget);
      expect(find.byType(DetailImagePager), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);
      // The shared page-counter overlay and the meta column's info block
      // both render.
      expect(find.byType(DetailPageCounter), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('作品说明文字'), findsOneWidget);
    });

    testWidgets('arrow keys page the image pane', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
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
