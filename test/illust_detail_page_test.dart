import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/person_avatar.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/features/illust/detail/widgets/detail_page_counter.dart';
import 'package:parfait/features/illust/detail/widgets/detail_section_header.dart';
import 'package:parfait/features/illust/detail/widgets/illust_detail_skeleton.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart';
import 'package:parfait/features/illust/detail/widgets/info_block.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/detail_world.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'helpers/prompt_host.dart';

import 'helpers/illust_detail_page_support.dart';
import 'helpers/localized_app.dart';

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
            localizedApp(
              container: container,
              builder: promptHostBuilder,
              home: IllustDetailPage(
                illustId: 42,
                initialEntity: entity,
                heroScope: 'profile:42:bookmarks:illust:public',
                heroImageUrl: 'https://i.pximg.net/feed/42/medium.jpg',
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

    testWidgets('the push frame builds no list item off screen', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      // Lazy list items; a sliver itself is built wherever it sits.
      int listItems() => find
          .descendant(
            of: find.bySubtype<CustomScrollView>().first,
            matching: find.byType(IndexedSemantics, skipOffstage: false),
            skipOffstage: false,
          )
          .evaluate()
          .length;

      // Short enough that the info list runs past the screen.
      await pumpDetail(
        tester,
        container,
        surface: const Size(390, 560),
        firstFrameOnly: true,
      );
      final pushFrame = listItems();
      // The cache area fills in on the next frame.
      await mockNetworkImagesFor(tester.pump);
      expect(listItems(), greaterThan(pushFrame));
      await mockNetworkImagesFor(
        () => tester.pump(const Duration(milliseconds: 50)),
      );
    });

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
        // The whole card is the target, not just the avatar or name.
        await tester.tap(find.byKey(const Key('illust-author-row')));
        await tester.pumpAndSettle();
      });
      expect(find.byType(UserPage), findsOneWidget);
    });
  });

  group('info block layout (R1)', () {
    testWidgets('a long caption collapses and expands; a short one does not', (
      tester,
    ) async {
      final long = [for (var i = 0; i < 12; i++) 'line $i'].join('<br>');
      final (container, _, _) = await makeWorld(
        detailOverrides: {
          42: illustJson(42, pageCount: 2, withMetaPages: true, caption: long),
        },
      );
      // A tall surface builds the whole info block below the two pages.
      const tall = Size(800, 4000);
      await pumpDetail(
        tester,
        container,
        locale: const Locale('zh', 'CN'),
        surface: tall,
      );
      await tester.pumpAndSettle();

      // Collapsed, the caption is painted twice; the first copy is whole.
      Text caption() =>
          tester.widget<Text>(find.textContaining('line 0').first);
      expect(caption().maxLines, InfoBlock.captionLines);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(caption().maxLines, isNull);
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(caption().maxLines, InfoBlock.captionLines);

      // The default world's caption is one short line.
      final (shortWorld, _, _) = await makeWorld();
      await pumpDetail(
        tester,
        shortWorld,
        locale: const Locale('zh', 'CN'),
        surface: tall,
      );
      await tester.pumpAndSettle();
      expect(find.text('作品说明文字'), findsOneWidget);
      expect(find.text('展开'), findsNothing);
    });

    testWidgets(
      'marks and tools show only when set; the ID copies; headings align',
      (tester) async {
        final clipboard = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final (container, _, _) = await makeWorld();
        await pumpDetail(
          tester,
          container,
          locale: const Locale('zh', 'CN'),
          surface: const Size(800, 4000),
        );
        await tester.pumpAndSettle();

        Finder fact(String text) => find.descendant(
          of: find.byKey(const Key('illust-detail-facts')),
          matching: find.text(text),
        );
        expect(fact('2 页'), findsOneWidget);
        expect(fact('800×600'), findsOneWidget);
        // A plain work: no marks, no tools.
        expect(find.text('AI 生成'), findsNothing);
        expect(find.text('R-18G'), findsNothing);
        expect(find.byIcon(Icons.brush_outlined), findsNothing);
        await tester.tap(find.byKey(const Key('illust-detail-id')));
        await tester.pump();
        expect(clipboard, ['42']);

        // The caption heading carries the translate button, the tags heading
        // none; the content starts where the heading row ends.
        double underHeading(String heading) {
          final row = find.ancestor(
            of: find.text(heading),
            matching: find.byType(DetailSectionHeader),
          );
          return tester.getBottomLeft(row).dy -
              tester.getBottomLeft(find.text(heading)).dy;
        }

        expect(underHeading('简介'), underHeading('标签'));

        // The detail payload brings the marks and tools in.
        final (marked, _, _) = await makeWorld(
          detailOverrides: {
            42: {
              ...illustJson(
                42,
                pageCount: 2,
                withMetaPages: true,
                aiType: 2,
                xRestrict: 2,
              ),
              'tools': ['Photoshop', 'SAI'],
            },
          },
        );
        // Narrow enough that the facts wrap.
        await pumpDetail(
          tester,
          marked,
          locale: const Locale('zh', 'CN'),
          surface: const Size(400, 4000),
        );
        await tester.pumpAndSettle();
        expect(find.text('AI 生成'), findsOneWidget);
        expect(find.text('R-18G'), findsOneWidget);
        expect(find.text('R-18'), findsNothing);
        expect(fact('Photoshop / SAI'), findsOneWidget);

        // The marks share the stats' line; the facts come after the tags,
        // every wrapped line starting its glyph on the margin.
        expect(
          tester.getCenter(find.text('AI 生成')).dy,
          moreOrLessEquals(
            tester.getCenter(find.byIcon(Icons.visibility_outlined)).dy,
            epsilon: 1,
          ),
        );
        final facts = find.byKey(const Key('illust-detail-facts'));
        expect(
          tester.getTopLeft(facts).dy,
          greaterThan(tester.getTopLeft(find.text('标签')).dy),
        );
        final glyphs = find.descendant(of: facts, matching: find.byType(Icon));
        final lineStarts = <double, double>{};
        for (var i = 0; i < glyphs.evaluate().length; i++) {
          final glyph = tester.getRect(glyphs.at(i));
          lineStarts.update(
            glyph.top,
            (left) => left < glyph.left ? left : glyph.left,
            ifAbsent: () => glyph.left,
          );
        }
        expect(lineStarts, hasLength(greaterThan(1)));
        expect(lineStarts.values, everyElement(FuncSpacing.lg));
      },
    );
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

    testWidgets(
      'a short first image sits a band low; Hero and badge keep to it',
      (tester) async {
        tester.view.padding = const FakeViewPadding(top: 24);

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
        // Where centering in 0.7 of the viewport would put it.
        final band = (844 * 0.7 - naturalHeight) / 2;
        expect(slot.top, closeTo(24, 0.5));
        expect(slot.height, closeTo(band + naturalHeight, 0.5));
        // The image starts below the toolbar: the controls sit bare.
        expect(lifted(tester), isFalse);
        expect(barGradient(), findsNothing);
        expect(tester.getRect(hero).height, closeTo(naturalHeight, 0.5));
        expect(tester.getRect(hero).top, closeTo(24 + band, 0.5));
        // No band below: what follows starts right under the image.
        expect(tester.getRect(hero).bottom, closeTo(slot.bottom, 0.5));
        // The pager's stand-in for an unbuilt page draws at the same frame,
        // so a swipe does not land on a jump.
        final frame = detailFirstImageFrame(
          tester.element(find.byType(IllustDetailPage)),
          container.read(illustStoreProvider).get(42)!,
        );
        expect(frame.top, closeTo(tester.getRect(hero).top, 0.5));
        expect(frame.height, closeTo(naturalHeight, 0.5));

        // Selecting, the badge sits as far into the image's top as into its
        // end: the toolbar does not reach the image.
        await longPressImage(tester);
        final mark = tester.getRect(find.byIcon(Icons.radio_button_unchecked));
        final image = tester.getRect(hero);
        expect(mark.top - image.top, closeTo(image.right - mark.right, 0.5));
      },
    );

    testWidgets('gives the first image of a set the same slot', (tester) async {
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

      // Collapsed, the set shows page 1 only, the band above it and the
      // expand button right under it.
      const natural = 219.375;
      final slot = tester.getRect(find.byType(DetailPageImage));
      expect(slot.height, closeTo((844 * 0.7 + natural) / 2, 0.5));
      expect(
        tester.getRect(find.byKey(const Key('illust-expand-pages'))).top,
        closeTo(slot.bottom, 0.5),
      );
      expect(lifted(tester), isFalse);

      // Expanded, page 1 springs to its natural height under the toolbar,
      // and the controls take the artwork look over it.
      await tester.tap(find.byKey(const Key('illust-expand-pages')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(DetailPageImage).first),
        rectMoreOrLessEquals(Rect.fromLTWH(0, 0, 390, natural), epsilon: 0.5),
      );
      expect(lifted(tester), isTrue);
      expect(barGradient(), findsNothing);

      // Under the toolbar, page 1's badge keeps that inset below the bar.
      await longPressImage(tester);
      final mark = tester.getRect(
        find.byIcon(Icons.radio_button_unchecked).first,
      );
      expect(mark.top - kToolbarHeight, closeTo(390 - mark.right, 0.5));
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
        surface: surface,
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

      // Page 3 with the set's own collapse button under it: the count
      // stays, the pill steps aside — one "collapse" at a time.
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('illust-collapse-pages'));
      expect(page(2), findsOneWidget);
      expect(toggle, findsOneWidget);
      expect(find.byType(PageCountPill), findsOneWidget);
      expect(pill, findsNothing);

      // The button below the screen again: the pill returns, and folds
      // the set from there.
      position.jumpTo(position.pixels + tester.getTopLeft(toggle).dy - 550);
      await tester.pumpAndSettle();
      expect(page(2), findsOneWidget);
      expect(pill, findsOneWidget);
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

    testWidgets('requests related works only once the section is on screen; '
        'the local block filters them (R7)', (tester) async {
      final log = <int>[];
      final (container, _, _) = await makeWorld(
        relatedLog: log,
        relatedOverrides: {
          42: [illustJson(900, xRestrict: 1), illustJson(901, pageCount: 1)],
        },
        extraOverrides: [filterSettings(blockR18: true)],
      );
      await pumpDetail(tester, container);
      await mockNetworkImagesFor(() async {
        await tester.pump(const Duration(milliseconds: 300));
        // A short scroll that keeps the section below the fold.
        await tester.drag(
          find.bySubtype<CustomScrollView>(),
          const Offset(0, -80),
        );
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(log, isEmpty, reason: 'opening the page sends no request');

      await mockNetworkImagesFor(() => scrollToRelated(tester));
      expect(log, [42]);
      expect(find.text('illust 901'), findsOneWidget);
      expect(find.text('illust 900'), findsNothing);

      // Scrolling away and back, and the bottom-of-page paging check, do
      // not send the first request again.
      await mockNetworkImagesFor(() async {
        await tester.drag(
          find.bySubtype<CustomScrollView>(),
          const Offset(0, 900),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await scrollToRelated(tester);
      });
      expect(log, [42]);
    });

    testWidgets('related works all filtered: the section offers loading on, '
        'reaching the bottom does not load (FEED-22)', (tester) async {
      final log = <int>[];
      final (container, _, _) = await makeWorld(
        relatedLog: log,
        relatedOverrides: {
          42: [illustJson(900, xRestrict: 1)],
        },
        relatedEndless: true,
        extraOverrides: [filterSettings(blockR18: true)],
      );
      await pumpDetail(tester, container);
      await mockNetworkImagesFor(() async {
        // The first page and its three refills, all filtered out.
        await scrollToRelated(tester);
        // Reaching the page's bottom again loads nothing on its own.
        await scrollToRelated(tester);
      });
      expect(log, hasLength(4));
      expect(find.text('illust 900'), findsNothing);

      await tester.tap(find.text('Continue loading'));
      await tester.pump(const Duration(seconds: 5));
      expect(log, hasLength(8));
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
            tester.widget<CustomScrollView>(find.bySubtype<CustomScrollView>());
        final scrollView = body();

        // Jump past page 2's bottom edge so page 3 is the only visible
        // artwork — deterministic, no fling physics involved.
        final pageHeight = tester
            .getSize(find.byType(DetailPageImage).first)
            .height;
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(2 * pageHeight + 100);
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
        expect(find.text('相关作品'), findsOneWidget);
        expect(find.byType(PageCountPill), findsNothing);
      },
    );

    testWidgets('tapping the pill spot reaches the artwork viewer', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      // Wide enough that the artwork fills its slot up to the pill.
      await pumpDetail(
        tester,
        container,
        useRouter: true,
        surface: const Size(800, 800),
      );
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
