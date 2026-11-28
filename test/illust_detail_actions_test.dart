import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:parfait/app/clipboard.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/navigation/route_extras.dart';
import 'package:parfait/app/widgets/comment_composer.dart';
import 'package:parfait/app/widgets/comment_text.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/core/bookmark/bookmark_tag_providers.dart';
import 'package:parfait/core/comments/comment_assets.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/platform/image_clipboard.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_shells.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/illust/detail/widgets/detail_image_pager.dart';
import 'package:parfait/features/illust/detail/widgets/detail_overlay_frame.dart';
import 'package:parfait/features/search/tag_search_page.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/detail_world.dart';
import 'helpers/illust_detail_page_support.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart' show RecordingTranslationEngine;
import 'helpers/view_size.dart';
import 'helpers/waits.dart';

/// A phone short enough that the sections under the info block start
/// below the fold.
const _short = Size(390, 560);

void main() {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  group('floating action bar (E2)', () {
    Finder inBar(Finder finder) =>
        find.descendant(of: find.byType(DetailActionBar), matching: finder);

    Rect toolbarRect(WidgetTester tester) =>
        tester.getRect(inBar(find.byType(Material)).first);

    testWidgets('slides away reading down, returns reading up, and stays '
        'while TalkBack explores', (tester) async {
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
  });

  group('comment preview and author works (§2-E)', () {
    Future<void> showSection(WidgetTester tester, Finder header) async {
      await tester.scrollUntilVisible(
        header,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(header), alignment: 0.3);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
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
        Future<void> settle() async {
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
        }

        await tester.tap(
          find.descendant(of: entry, matching: find.byTooltip('贴图')),
        );
        await settle();
        expect(composer().debugInputState, CommentComposerInputState.stamp);
        expect(bar(), 0);
        await tester.binding.handlePopRoute();
        await settle();
        expect(find.byType(CommentComposer), findsNothing);
        expect(find.byType(IllustDetailPage), findsOneWidget);
        expect(bar(), 1);

        await tester.tap(
          find.descendant(of: entry, matching: find.text('添加评论')),
        );
        await settle();
        await tester.enterText(find.byType(TextField), 'hello');
        await tester.tap(find.byTooltip('表情'));
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

        await tester.tap(find.byIcon(AppIcons.send));
        await settle();
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

      await tester.tap(tile('illust 501'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 501,
        ),
        findsOneWidget,
      );
    });
  });

  group('detail overflow menu (R3)', () {
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
      expect(find.text('Bookmark illustration'), findsOneWidget);
    });
  });

  group('tag action menu (R3)', () {
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
              indexTranslate: engine,
            ),
          ),
        ],
      );
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await longPressFirstTag(tester);

      await tester.tap(find.text('翻译标签名'));
      await tester.pumpAndSettle();
      expect(find.text('去设置'), findsOneWidget);
      final rowIcon = find.descendant(
        of: find.widgetWithText(ListTile, '翻译标签名'),
        matching: find.byIcon(AppIcons.translate),
      );
      expect(tester.widget<Icon>(rowIcon).color, isNull);

      provider = TranslationProvider.google;
      await tester.tap(find.text('翻译标签名'));
      await tester.pumpAndSettle();
      expect(find.text('TAG-IN-ZH'), findsOneWidget);
      expect(find.text('收起翻译'), findsOneWidget);
      expect(engine.sources, ['original']);
    });

    testWidgets('mute writes MuteStore.tags and a muted tag offers 解除屏蔽', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));

      await longPressFirstTag(tester);
      await tester.tap(find.text('屏蔽该标签'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(muteStoreProvider).tags, contains('original'));

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

        await longPressFirstTag(tester);
        await tester.tap(find.text('批量屏蔽标签'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TagChip>(find.byType(TagChip).first).blockMode,
          isTrue,
        );

        await longPressFirstTag(tester);
        await tester.tap(find.text('搜索该标签'));
        await tester.pumpAndSettle();
        expect(find.byType(TagSearchPage), findsOneWidget);
      },
    );
  });

  group('overlay and desktop clipboard', () {
    testWidgets('tabletop hinge splits artwork above inspector action bar', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      setViewSize(tester, const Size(884, 740));
      tester.view.displayFeatures = const [
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(0, 364, 884, 12),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
          home: const IllustDetailPage(illustId: 42),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      final pager = tester.getRect(find.byType(DetailImagePager));
      final bar = tester.getRect(
        find.byKey(const ValueKey('detail-inspector-action-bar')),
      );
      expect(pager.bottom, lessThanOrEqualTo(364));
      expect(bar.top, greaterThanOrEqualTo(376));
      expect(find.byType(DetailActionBar), findsNothing);
    });

    testWidgets(
      'IllustDetailTwoPaneShell applies SafeArea insets outside overlay and adapts for tabletop hinge',
      (tester) async {
        final (container, _, _) = await makeWorld();
        final entity = parseIllust(
          illustJson(42, pageCount: 1, withMetaSinglePage: true),
        );
        final scroll = ScrollController();
        addTearDown(scroll.dispose);

        Widget twoPaneShell(String heroScope) => IllustDetailTwoPaneShell(
          entity: entity,
          detailUrlFor: (_) => null,
          downloadMode: false,
          selectedPages: const {},
          onToggleSelect: (_) {},
          onLongPress: () {},
          heroScope: heroScope,
          initialPage: 0,
          onPageChanged: (_) {},
          heroImageUrl: null,
          heroImageDecodeWidth: null,
          inspectorHeader: const SizedBox(
            key: ValueKey('h15-inspector-header'),
            height: 48,
          ),
          metaScrollController: scroll,
          metaSlivers: const [SliverToBoxAdapter(child: SizedBox(height: 120))],
          onScrollNotification: (_) => false,
          composerLayer: null,
        );

        Widget buildShell({
          required Size size,
          required EdgeInsets padding,
          List<ui.DisplayFeature> features = const [],
        }) => localizedApp(
          container: container,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: size,
                padding: padding,
                viewPadding: padding,
                displayFeatures: features,
              ),
              child: Scaffold(body: twoPaneShell('h15')),
            ),
          ),
        );

        // 1. Non-overlay side-by-side: clears top/left/right safe areas.
        setViewSize(tester, const Size(1200, 800));
        await tester.pumpWidget(
          buildShell(
            size: const Size(1200, 800),
            padding: const EdgeInsets.fromLTRB(16, 36, 12, 24),
          ),
        );
        await tester.pump();
        final backSide = tester.getRect(
          find.byKey(const ValueKey('two-pane-primary-back')),
        );
        final headerSide = tester.getRect(
          find.byKey(const ValueKey('h15-inspector-header')),
        );
        expect(backSide.top, closeTo(48, 0.5));
        expect(backSide.left, closeTo(28, 0.5));
        expect(headerSide.top, closeTo(36, 0.5));
        expect(headerSide.right, closeTo(1188, 0.5));

        // 2. Non-overlay tabletop hinge: primary clears top+sides; secondary
        //    sits below the hinge without duplicate top inset.
        setViewSize(tester, const Size(900, 800));
        await tester.pumpWidget(
          buildShell(
            size: const Size(900, 800),
            padding: const EdgeInsets.fromLTRB(16, 36, 12, 24),
            features: const [
              ui.DisplayFeature(
                bounds: Rect.fromLTWH(0, 390, 900, 20),
                type: ui.DisplayFeatureType.hinge,
                state: ui.DisplayFeatureState.postureHalfOpened,
              ),
            ],
          ),
        );
        await tester.pump();
        final backTabletop = tester.getRect(
          find.byKey(const ValueKey('two-pane-primary-back')),
        );
        final headerTabletop = tester.getRect(
          find.byKey(const ValueKey('h15-inspector-header')),
        );
        expect(backTabletop.top, closeTo(48, 0.5));
        expect(backTabletop.left, closeTo(28, 0.5));
        expect(headerTabletop.top, closeTo(411, 1.5));
        expect(headerTabletop.left, closeTo(16, 0.5));
        expect(headerTabletop.right, closeTo(888, 0.5));

        // 3. Modal overlay frame: DetailOverlayFrame owns outer SafeArea.
        setViewSize(tester, const Size(1200, 800));
        await tester.pumpWidget(
          localizedApp(
            container: container,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: const Size(1200, 800),
                padding: const EdgeInsets.fromLTRB(16, 36, 12, 24),
                viewPadding: const EdgeInsets.fromLTRB(16, 36, 12, 24),
              ),
              child: child!,
            ),
            home: Builder(
              builder: (rootContext) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(rootContext).push<void>(
                    PageRouteBuilder<void>(
                      opaque: false,
                      pageBuilder: (_, _, _) =>
                          DetailOverlayFrame(child: twoPaneShell('h15-modal')),
                    ),
                  ),
                  child: const Text('open-overlay'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('open-overlay'));
        await tester.pumpAndSettle();
        final shellRect = tester.getRect(find.byType(IllustDetailTwoPaneShell));
        final backModal = tester.getRect(
          find.byKey(const ValueKey('two-pane-primary-back')),
        );
        final headerModal = tester.getRect(
          find.byKey(const ValueKey('h15-inspector-header')),
        );
        expect(backModal.top - shellRect.top, closeTo(12, 0.5));
        expect(headerModal.top - shellRect.top, closeTo(0, 0.5));

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );

    testWidgets(
      'bounded wide detail overlay keeps underlying feed alive and closes on '
      'scrim tap',
      (tester) async {
        setViewSize(tester, const Size(1440, 900));
        final (container, _, _) = await makeWorld();
        final entity = parseIllust(
          illustJson(42, pageCount: 2, withMetaPages: true),
        );
        container.read(illustStoreProvider).mergeAll([entity]);
        final router = pixivRouter('/recommended');
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          localizedRouterApp(router, container: container),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        unawaited(
          router.push<void>(
            '/recommended/illust/42',
            extra: IllustRouteExtra(entity: entity),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final scrimFinder = find.byKey(const ValueKey('detail-overlay-scrim'));
        expect(scrimFinder, findsOneWidget);
        expect(find.byType(RecommendedHomePage), findsOneWidget);

        final scrim = tester.getRect(scrimFinder);
        await tester.tapAt(scrim.topLeft + const Offset(8, 8));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/recommended');
        expect(scrimFinder, findsNothing);
      },
    );

    testWidgets(
      'ImageClipboard channel and copy-image action copy original bytes with desktop-only gating and deferAppSnackBar',
      (tester) async {
        for (final (platform, expected) in [
          (TargetPlatform.windows, true),
          (TargetPlatform.macOS, true),
          (TargetPlatform.linux, true),
          (TargetPlatform.android, false),
          (TargetPlatform.iOS, false),
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          try {
            expect(
              isDesktopImageClipboardSupported,
              expected,
              reason: 'desktop image clipboard gating on $platform',
            );
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }

        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          const channel = MethodChannel('parfait/image_clipboard');
          final copiedPaths = <String>[];
          var channelResult = true;
          Completer<bool>? pendingReply;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'copyImageFile') {
                  final args = call.arguments as Map<dynamic, dynamic>;
                  copiedPaths.add(args['path'] as String);
                  if (pendingReply case final pending?) {
                    return pending.future;
                  }
                  return channelResult;
                }
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );

          final worker = inProcessImageWorker(
            () =>
                MockClient((_) async => http.Response.bytes(onePixelPng, 200)),
          );
          final (container, _, _) = await makeWorld(
            extraOverrides: [imageWorkerProvider.overrideWithValue(worker)],
          );
          final entity = parseIllust(
            illustJson(42, pageCount: 1, withMetaSinglePage: true),
          );
          final mountHost = ValueNotifier<bool>(true);
          addTearDown(mountHost.dispose);
          BuildContext? openerContext;

          await tester.pumpWidget(
            localizedApp(
              container: container,
              builder: promptHostBuilder,
              body: ValueListenableBuilder<bool>(
                valueListenable: mountHost,
                builder: (context, show, _) => show
                    ? Builder(
                        builder: (inner) {
                          openerContext = inner;
                          return const Text('opener');
                        },
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          );
          await tester.pump();

          pendingReply = Completer<bool>();
          unawaited(
            copyIllustOriginalImageToClipboard(
              openerContext!,
              container,
              entity,
            ),
          );
          await pumpIoUntil(tester, () => copiedPaths.length == 1);
          mountHost.value = false;
          await tester.pump();
          pendingReply.complete(true);
          pendingReply = null;
          await tester.pump();
          await tester.pumpAndSettle();
          expect(copiedPaths, hasLength(1));
          expect(
            File(copiedPaths.single).readAsBytesSync(),
            orderedEquals(onePixelPng),
          );
          expect(
            find.text(lookupAppLocalizations(zhCN).imageCopiedToClipboard),
            findsOneWidget,
          );

          await tester.pump(const Duration(seconds: 5));
          mountHost.value = true;
          await tester.pump();
          channelResult = false;
          unawaited(
            copyIllustOriginalImageToClipboard(
              openerContext!,
              container,
              entity,
            ),
          );
          await pumpIoUntil(tester, () => copiedPaths.length == 2);
          await tester.pumpAndSettle();
          expect(
            find.text(lookupAppLocalizations(zhCN).imageCopyFailed),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
