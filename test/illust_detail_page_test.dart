import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/person_avatar.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/features/illust/detail/widgets/detail_page_counter.dart';
import 'package:parfait/features/illust/detail/widgets/illust_detail_skeleton.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/detail/widgets/info_block.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/detail_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'helpers/prompt_host.dart';

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

  group('IllustDetailPage badges & restricted states (R1/R2)', () {
    testWidgets('visible:false detail shows the restricted state', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        detailOverrides: {42: illustJson(42, visible: false)},
      );
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('该作品已被删除或受限（ID: 42）'), findsOneWidget);
    });

    testWidgets(
      'U5: the card snapshot renders on the very first frame with the '
      'Hero destination present',
      (tester) async {
        final (container, _, _) = await makeWorld();
        final entity = parseIllust(
          illustJson(42, pageCount: 1, width: 800, height: 100),
        );

        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                builder: promptHostBuilder,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh', 'CN'),

                home: IllustDetailPage(
                  illustId: 42,
                  initialEntity: entity,
                  heroScope: 'profile:42:bookmarks:illust:public',
                  heroImageUrl: 'https://i.pximg.net/feed/42/medium.jpg',
                ),
              ),
            ),
          );
          // No second pump / settle: this is the AsyncLoading first frame.
          expect(find.byType(ProgressIndicator), findsNothing);
          expect(find.byType(IllustDetailSkeleton), findsNothing);
          expect(
            find.byType(Scrollable),
            findsWidgets,
            reason: 'content renders from the card snapshot, not a spinner',
          );
          // The snapshot proves out through the InfoBlock title — the
          // detail page keeps no separate title copy anymore.
          expect(
            find.descendant(
              of: find.byType(InfoBlock),
              matching: find.text('illust 42'),
            ),
            findsOneWidget,
          );
          expect(find.text('author'), findsWidgets);
          expect(
            tester.widget<PixivImage>(find.byType(PixivImage).first).url,
            'https://i.pximg.net/feed/42/medium.jpg',
            reason: 'the Hero target must reuse the exact feed cache key',
          );
          expect(find.byKey(const Key('illust-author-row')), findsOneWidget);
          expect(find.byType(PersonAvatar), findsOneWidget);
          expect(
            tester.widget<PersonAvatar>(find.byType(PersonAvatar)).imageUrl,
            isNotNull,
            reason: 'the author avatar provider exists in the first frame',
          );
          // Hero destination exists on the first frame (feed -> detail flight).
          final hero = tester.widget<Hero>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Hero &&
                  widget.tag ==
                      'IllustHero:profile:42:bookmarks:illust:public:42',
            ),
          );
          expect(hero, isNotNull);
          expect(hero.flightShuttleBuilder, illustHeroFlightShuttleBuilder);
        });
      },
    );

    testWidgets(
      'without a store snapshot the first load shows the detail skeleton',
      (tester) async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final (container, _, _) = await makeWorld(detailGate: gate);
        await pumpDetail(tester, container, seedStore: false);

        expect(find.byType(IllustDetailSkeleton), findsOneWidget);
        expect(find.byType(FeedLoading), findsNothing);
        expect(find.byType(ProgressIndicator), findsNothing);

        gate.complete();
        // The loaded detail replaces the skeleton and fades in.
        for (var i = 0; i < 20; i++) {
          if (find.byType(IllustDetailSkeleton).evaluate().isEmpty) break;
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(find.byType(IllustDetailSkeleton), findsNothing);
        expect(stateFadeOpacity(tester), lessThan(1));
        await tester.pumpAndSettle();
        expect(stateFadeOpacity(tester), 1);
        // The first page image at the top of the scroll proves the entity
        // rendered — the InfoBlock title sits below the fold of a lazy
        // sliver.
        expect(
          find.byKey(const ValueKey<Object?>('illust-page-42-0')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'U6: caption renders as rich clickable text, not literal HTML',
      (tester) async {
        final (container, _, _) = await makeWorld(
          detailOverrides: {
            42: illustJson(
              42,
              caption:
                  'line1<br>line2 — <a '
                  'href="https://www.pixiv.net/users/7">author</a> '
                  '&amp; more',
            ),
          },
        );
        await pumpDetail(tester, container, useRouter: true);
        await mockNetworkImagesFor(() async {
          await tester.scrollUntilVisible(
            find.textContaining('line1'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump();
        });

        // The key assertions: no literal `<br />` text, the caption text
        // renders decoded, and tapping an in-app pixiv link pushes a route.
        // ('author' also names the author block, hence .last.)
        expect(find.textContaining('<br>'), findsNothing);
        expect(find.textContaining('line1'), findsOneWidget);
        expect(find.text('author'), findsWidgets);
        expect(find.text('简介'), findsNothing);

        await tester.tap(find.text('author').last);
        await tester.pumpAndSettle();
        expect(
          find.byType(Scaffold).evaluate().length,
          greaterThanOrEqualTo(2),
          reason: 'in-app pixiv link pushes a detail page route',
        );
      },
    );
  });

  group('IllustDetailPage author block & i18n (U9 / C20)', () {
    testWidgets('U9: tapping the author block opens the user page', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, useRouter: true);
      await mockNetworkImagesFor(() async {
        await tester.scrollUntilVisible(
          find.byKey(const Key('illust-author-row')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        // Mid-screen, clear of the floating action bar.
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const Key('illust-author-row'))),
          alignment: 0.5,
        );
        await tester.pump();
      });

      expect(find.byType(UserPage), findsNothing);
      await mockNetworkImagesFor(() async {
        // The avatar is the smallest of the three hit areas; the InkWell
        // wraps the whole Row, so a tap on it must reach the same callback.
        await tester.tap(find.byKey(const Key('illust-author-row')));
        await tester.pumpAndSettle();
      });
      expect(find.byType(UserPage), findsOneWidget);
    });
  });

  group('info block layout (R1)', () {
    /// A tall surface builds the whole info block below the two pages.
    void useTallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('a long caption collapses and expands; a short one does not', (
      tester,
    ) async {
      useTallSurface(tester);
      final long = [for (var i = 0; i < 12; i++) 'line $i'].join('<br>');
      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(42, pageCount: 2, withMetaPages: true, caption: long),
        },
      );
      await pumpDetail(tester, container, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();

      Text caption() => tester.widget<Text>(find.textContaining('line 0'));
      expect(caption().maxLines, InfoBlock.captionLines);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(caption().maxLines, isNull);
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(caption().maxLines, InfoBlock.captionLines);

      // The default world's caption is one short line.
      final (shortWorld, _, _) = await makeWorld();
      await pumpDetail(tester, shortWorld, locale: const Locale('zh', 'CN'));
      await tester.pumpAndSettle();
      expect(find.text('作品说明文字'), findsOneWidget);
      expect(find.text('展开'), findsNothing);
    });
  });

  group('narrow first image slot', () {
    // Whether the bar's controls take the artwork look: a halo traced
    // around the bare glyph, never a disc under it.
    bool lifted(WidgetTester tester) {
      final glyph = tester.element(
        find
            .descendant(of: find.byType(AppTopBar), matching: find.byType(Icon))
            .first,
      );
      final disc = IconButtonTheme.of(
        glyph,
      ).style?.backgroundColor?.resolve(const {});
      expect(disc == null || disc.a == 0, isTrue);
      return IconTheme.of(glyph).shadows?.isNotEmpty ?? false;
    }

    // The bar never dims the artwork with a gradient.
    Finder barGradient() => find.descendant(
      of: find.byType(AppTopBar),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient != null,
      ),
    );

    testWidgets('centers a short first image below the status bar without '
        'changing its Hero rect', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.reset);

      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(42, pageCount: 1, width: 1600, height: 900),
        },
      );
      container.read(illustStoreProvider).mergeAll([
        parseIllust(illustJson(42, pageCount: 1, width: 1600, height: 900)),
      ]);
      await pumpDetail(
        tester,
        container,
        seedStore: false,
        locale: const Locale('zh', 'CN'),
      );
      await tester.pumpAndSettle();

      final slot = tester.getRect(find.byType(DetailPageImage));
      final hero = find.byWidgetPredicate(
        (widget) => widget is Hero && widget.tag == illustHeroTag('feed', 42),
      );
      final naturalHeight = 390 / (1600 / 900);
      expect(slot.top, closeTo(24, 0.5));
      expect(slot.height, closeTo(844 * 0.7, 0.5));
      // The image starts below the toolbar: the controls sit bare.
      expect(lifted(tester), isFalse);
      expect(barGradient(), findsNothing);
      expect(tester.getRect(hero).height, closeTo(naturalHeight, 0.5));
      expect(tester.getRect(hero).center.dy, closeTo(slot.center.dy, 0.5));
      // The pager's stand-in for an unbuilt page draws at the same frame,
      // so a swipe does not land on a jump.
      final frame = detailFirstImageFrame(
        tester.element(find.byType(IllustDetailPage)),
        container.read(illustStoreProvider).get(42)!,
      );
      expect(frame.top, closeTo(tester.getRect(hero).top, 0.5));
      expect(frame.height, closeTo(naturalHeight, 0.5));
    });

    testWidgets('gives the first image of a set the same slot', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(
            42,
            pageCount: 2,
            withMetaPages: true,
            width: 1600,
            height: 900,
          ),
        },
      );
      container.read(illustStoreProvider).mergeAll([
        parseIllust(
          illustJson(
            42,
            pageCount: 2,
            withMetaPages: true,
            width: 1600,
            height: 900,
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

      // Collapsed, the set shows page 1 only.
      expect(
        tester.getSize(find.byType(DetailPageImage)).height,
        closeTo(844 * 0.7, 0.5),
      );
      expect(lifted(tester), isFalse);

      // Expanded, page 1 springs to its natural height under the toolbar,
      // and the controls take the artwork look over it.
      await tester.tap(find.byKey(const Key('illust-expand-pages')));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(DetailPageImage).first).height,
        closeTo(219.375, 0.5),
      );
      expect(lifted(tester), isTrue);
      expect(barGradient(), findsNothing);
    });
  });

  group('multi-image pages (R2)', () {
    Finder page(int index) =>
        find.byKey(ValueKey<Object?>('illust-page-42-$index'));

    Future<ProviderContainer> pumpWork(
      WidgetTester tester, {
      required String type,
      Size surface = const Size(800, 4000),
    }) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final json = illustJson(
        42,
        pageCount: 3,
        type: type,
        withMetaPages: true,
      );
      final (container, _, _) = await makeWorld(detailOverrides: {42: json});
      container.read(illustStoreProvider).mergeAll([parseIllust(json)]);
      await pumpDetail(
        tester,
        container,
        seedStore: false,
        locale: const Locale('en', 'US'),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('an illustration set opens on its first image', (tester) async {
      await pumpWork(tester, type: 'illust');
      expect(page(0), findsOneWidget);
      expect(page(1), findsNothing);
      final expand = find.byKey(const Key('illust-expand-pages'));
      expect(find.text('Show all 3 images'), findsOneWidget);
      expect(
        tester.getSemantics(expand),
        matchesSemantics(
          label: 'Show all 3 images',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasExpandedState: true,
        ),
      );
      expect(tester.getSize(expand).height, greaterThanOrEqualTo(48));

      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(page(1), findsOneWidget);
      expect(page(2), findsOneWidget);
      // The button follows the last page and now folds the set back.
      expect(expand, findsNothing);
      final collapse = find.byKey(const Key('illust-collapse-pages'));
      expect(
        tester.getSemantics(collapse),
        isSemantics(label: 'Collapse', isButton: true, isExpanded: true),
      );
      expect(
        tester.getTopLeft(collapse).dy,
        greaterThan(tester.getBottomLeft(page(2)).dy - 1),
      );
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(page(1), findsNothing);
      expect(expand, findsOneWidget);
    });

    testWidgets('the pill over the pages folds the set back; a reader past '
        'page 1 lands where the set ends', (tester) async {
      // Short enough that the folded list can still scroll page 1 away.
      await pumpWork(tester, type: 'illust', surface: const Size(400, 500));
      // Collapsed: the count has no fold pill.
      final pill = find.byKey(const Key('illust-collapse-pages-floating'));
      expect(pill, findsNothing);
      await tester.tap(find.byKey(const Key('illust-expand-pages')));
      await tester.pumpAndSettle();
      expect(pill, findsOneWidget);
      expect(tester.getSize(pill).height, greaterThanOrEqualTo(48));

      // Read on into page 3, then fold from the pill.
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      expect(page(2), findsOneWidget);
      await tester.tap(pill);
      await tester.pumpAndSettle();

      expect(page(1), findsNothing);
      expect(pill, findsNothing);
      // Page 1 ends right under the top bar, the expand button right
      // after it — as far as the shorter list can scroll.
      final topChrome = tester.getBottomLeft(find.byType(AppTopBar)).dy;
      final firstPageEnd = tester.getSize(page(0)).height - topChrome;
      expect(position.maxScrollExtent, greaterThan(firstPageEnd));
      expect(position.pixels, closeTo(firstPageEnd, 0.5));
    });

    testWidgets('an ultra-wide page gets a fixed-height horizontal viewport', (
      tester,
    ) async {
      final json = illustJson(42, width: 4000, height: 100);
      final (container, _, _) = await makeWorld(detailOverrides: {42: json});
      await mockNetworkImagesFor(() async {
        await pumpDetail(tester, container, locale: const Locale('en', 'US'));
        await tester.pumpAndSettle();
      });

      final frame = find.byKey(const ValueKey('panorama-frame'));
      expect(frame, findsOneWidget);
      expect(tester.getSize(frame).height, closeTo(280, 0.1));
      expect(find.byType(SingleChildScrollView), findsWidgets);
    });
  });

  group('Related works (official detail-page section)', () {
    testWidgets('tapping a related tile opens its own detail page', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld(
        relatedOverrides: {
          42: [illustJson(901, pageCount: 1)],
        },
      );
      await pumpDetail(tester, container, useRouter: true);
      await mockNetworkImagesFor(() async {
        await scrollToRelated(tester);
        // Ensure the tile is visible before tapping (it may sit below the
        // fold after the second drag).
        await tester.scrollUntilVisible(
          find.text('illust 901'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump(const Duration(milliseconds: 50));
        // Tap the related card's image area (IllustCard's onTap covers the
        // image; the title row below is not clickable).
        final relatedHero = find.byWidgetPredicate(
          (w) => w is Hero && '${w.tag}'.contains('901'),
        );
        await tester.tapAt(tester.getRect(relatedHero).center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 350));
      });
      // The related section is a feed grid, so the tile opens the
      // work-to-work pager across the related list — the
      // pushed route is a pager whose landing work is 901.
      // (skipOffstage: the freshly pushed route is still in transition.)
      expect(find.byType(IllustDetailPagerPage), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is IllustDetailPage && w.illustId == 901,
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('requests related works only once the section is on screen', (
      tester,
    ) async {
      final log = <int>[];
      final (container, _, _) = await makeWorld(
        relatedLog: log,
        relatedOverrides: {
          42: [illustJson(901, pageCount: 1)],
        },
      );
      await pumpDetail(tester, container);
      await mockNetworkImagesFor(() async {
        await tester.pump(const Duration(milliseconds: 300));
        // A short scroll that keeps the section below the fold.
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(log, isEmpty, reason: 'opening the page sends no request');

      await mockNetworkImagesFor(() => scrollToRelated(tester));
      expect(log, [42]);
      expect(find.text('illust 901'), findsOneWidget);

      // Scrolling away and back, and the bottom-of-page paging check, do
      // not send the first request again.
      await mockNetworkImagesFor(() async {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 900));
        await tester.pump(const Duration(milliseconds: 200));
        await scrollToRelated(tester);
      });
      expect(log, [42]);
    });
  });

  group('narrow page counter (R1/R2)', () {
    testWidgets(
      'the counter follows the scrolled page and leaves with the artwork',
      (tester) async {
        // Manga shows every page. Related works make the meta tail taller
        // than the viewport —
        // scrolling to the bottom leaves every page fully off screen.
        final (container, _, _) = await makeWorld(
          detailOverrides: {
            42: illustJson(
              42,
              pageCount: 3,
              type: 'manga',
              withMetaPages: true,
              caption: '作品说明文字',
            ),
          },
          relatedOverrides: {
            42: [
              illustJson(901),
              illustJson(902),
              illustJson(903),
              illustJson(904),
            ],
          },
        );
        container.read(illustStoreProvider).mergeAll([
          parseIllust(
            illustJson(
              42,
              pageCount: 3,
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

        expect(find.text('1 / 3'), findsOneWidget);
        // The top bar redraws as it scrolls (immersion); the page body is
        // what must stay put.
        CustomScrollView body() =>
            tester.widget<CustomScrollView>(find.byType(CustomScrollView));
        final scrollView = body();

        // Jump past page 2's bottom edge so page 3 is the only visible
        // artwork — deterministic, no fling physics involved.
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(1500);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('3 / 3'), findsOneWidget);
        // Only the pill followed: the page itself did not rebuild.
        expect(identical(body(), scrollView), isTrue);

        // Scrolling past the artwork to the bottom leaves no page
        // visible — the pill fades out with it. The first jump brings the
        // related section on screen, which loads it on demand; the second
        // lands on the bottom of the now taller page.
        for (var i = 0; i < 2; i++) {
          final position = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          position.jumpTo(position.maxScrollExtent);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(find.text('作品说明文字'), findsOneWidget);
        expect(find.byType(PageCountPill), findsNothing);
      },
    );

    testWidgets('tapping the pill spot reaches the artwork viewer', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, useRouter: true);
      await tester.pumpAndSettle();

      // The pill is IgnorePointer — a tap on it lands on the artwork
      // below and pushes the viewer.
      expect(find.byType(DetailPageCounter), findsOneWidget);
      final pill = find.descendant(
        of: find.byType(DetailPageCounter),
        matching: find.byType(DecoratedBox),
      );
      await mockNetworkImagesFor(() async {
        await tester.tapAt(tester.getCenter(pill));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      });
      expect(find.byType(ImageViewerPage), findsOneWidget);
    });
  });
}
