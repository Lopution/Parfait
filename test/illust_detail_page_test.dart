import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/person_avatar.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/caption_rich_text.dart';
import 'package:parfait/app/widgets/inline_translation.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_pager_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_page_counter.dart';
import 'package:parfait/features/illust/detail/widgets/illust_detail_skeleton.dart';
import 'package:parfait/features/illust/detail/widgets/info_block.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/detail_world.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_detail_page_support.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/recording_haptics.dart';

class _RecordingOpener implements OutboundUrlOpener {
  final urls = <String>[];

  @override
  Future<void> openExternal(String url) async => urls.add(url);
}

void main() {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

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
        expect(find.byType(ProgressIndicator), findsNothing);
        expect(find.byType(IllustDetailSkeleton), findsNothing);
        expect(find.byType(Scrollable), findsWidgets);
        expect(
          find.descendant(
            of: find.byType(InfoBlock),
            matching: find.text('illust 42'),
          ),
          findsOneWidget,
        );
        expect(find.text('author'), findsWidgets);
        expect(
          tester.widget<PixivImage>(workImages.first).url,
          'https://i.pximg.net/feed/42/medium.jpg',
        );
        expect(find.byKey(const Key('illust-author-row')), findsOneWidget);
        expect(find.byType(PersonAvatar), findsOneWidget);
        expect(
          tester.widget<PersonAvatar>(find.byType(PersonAvatar)).imageUrl,
          isNotNull,
        );
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
      },
    );

    for (final (href, opens) in [
      ('pixiv://users/7', true),
      ('https://www.pixiv.net/en/users/7/illustrations?p=1', true),
      ('https://www.pixiv.net/users/%FF/illustrations', false),
      ('https://user@www.pixiv.net/users/7/illustrations', false),
    ]) {
      testWidgets(
        'U6: caption renders as rich clickable text, not literal HTML ($href)',
        (tester) async {
          final seen = _RecordingOpener();
          final (container, _, _) = await makeWorld(
            detailOverrides: {
              42: illustJson(
                42,
                caption:
                    'line1<br>line2 — <a '
                    'href="$href">author</a> '
                    '&amp; more',
              ),
            },
            extraOverrides: [outboundUrlOpenerProvider.overrideWithValue(seen)],
          );
          await pumpDetail(tester, container, useRouter: true);
          await tester.scrollUntilVisible(
            find.textContaining('line1'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump();

          expect(find.textContaining('<br>'), findsNothing);
          expect(find.textContaining('line1'), findsOneWidget);
          expect(find.text('简介'), findsNothing);

          await tester.tapOnText(
            find.textRange.ofSubstring(
              'author',
              descendentOf: find.byType(CaptionRichText),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byWidgetPredicate((w) => w is UserPage && w.userId == 7),
            opens ? findsOneWidget : findsNothing,
          );
          expect(seen.urls, opens ? isEmpty : [href]);
        },
      );
    }
  });

  group('IllustDetailPage author block & i18n (U9 / C20)', () {
    testWidgets('U9: tapping the author block opens the user page', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(tester, container, useRouter: true);
      await tester.scrollUntilVisible(
        find.byKey(const Key('illust-author-row')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('illust-author-row'))),
        alignment: 0.5,
      );
      await tester.pump();

      expect(find.byType(UserPage), findsNothing);
      await tester.tap(find.byKey(const Key('illust-author-row')));
      await tester.pumpAndSettle();
      expect(find.byType(UserPage), findsOneWidget);
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
      expect(expand, findsNothing);
      final collapse = find.byKey(const Key('illust-collapse-pages'));
      expect(
        tester.getSemantics(collapse),
        isSemantics(label: 'Collapse', isButton: true, isExpanded: true),
      );
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      expect(page(1), findsNothing);
      expect(expand, findsOneWidget);
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
      await scrollToRelated(tester);
      await tester.scrollUntilVisible(
        find.text('illust 901'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 50));
      final relatedHero = find.byWidgetPredicate(
        (w) => w is Hero && '${w.tag}'.contains('901'),
      );
      await tester.tapAt(tester.getRect(relatedHero).center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 350));
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
      await seedFilterSettings(blockR18: true);
      final (container, _, _) = await makeWorld(
        relatedLog: log,
        relatedOverrides: {
          42: [illustJson(900, xRestrict: 1), illustJson(901, pageCount: 1)],
        },
      );
      await pumpDetail(tester, container);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.drag(
        find.bySubtype<CustomScrollView>(),
        const Offset(0, -80),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(log, isEmpty, reason: 'opening the page sends no request');

      await scrollToRelated(tester);
      expect(log, [42]);
      expect(find.text('illust 901'), findsOneWidget);
      expect(find.text('illust 900'), findsNothing);

      await tester.drag(
        find.bySubtype<CustomScrollView>(),
        const Offset(0, 900),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await scrollToRelated(tester);
      expect(log, [42]);
    });

    testWidgets('related works all filtered: the section offers loading on, '
        'reaching the bottom does not load (FEED-22)', (tester) async {
      final log = <int>[];
      await seedFilterSettings(blockR18: true);
      final (container, _, _) = await makeWorld(
        relatedLog: log,
        relatedOverrides: {
          42: [illustJson(900, xRestrict: 1)],
        },
        relatedEndless: true,
      );
      await pumpDetail(tester, container);
      await scrollToRelated(tester);
      await scrollToRelated(tester);
      expect(log, hasLength(4));
      expect(find.text('illust 900'), findsNothing);

      await tester.tap(find.text('Continue loading'));
      await tester.pump(const Duration(seconds: 5));
      expect(log, hasLength(8));
    });
  });

  group('counter pass-through and tag block mode', () {
    testWidgets('tapping the pill spot reaches the artwork viewer', (
      tester,
    ) async {
      final (container, _, _) = await makeWorld();
      await pumpDetail(
        tester,
        container,
        useRouter: true,
        surface: const Size(800, 1000),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DetailPageCounter), findsOneWidget);
      final pill = find.descendant(
        of: find.byType(DetailPageCounter),
        matching: find.byType(DecoratedBox),
      );
      await tester.tapAt(tester.getCenter(pill));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ImageViewerPage), findsOneWidget);
    });

    testWidgets(
      'two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText',
      (tester) async {
        await tester.pumpWidget(
          localizedApp(
            body: const SelectionArea(
              child: TranslationPanel(
                translating: false,
                translations: ['translated line'],
                failure: null,
              ),
            ),
          ),
        );
        expect(find.byType(SelectableText), findsNothing);
        expect(find.text('translated line'), findsOneWidget);

        final panoJson = {
          ...illustJson(42, pageCount: 1, width: 4000, height: 400),
          'tags': [
            {'name': 'sky'},
          ],
        };
        final (container, _, _) = await makeWorld(
          detailOverrides: {42: panoJson},
        );
        container.read(illustStoreProvider).mergeAll([parseIllust(panoJson)]);
        await pumpDetail(
          tester,
          container,
          seedStore: false,
          surface: const Size(1000, 700),
          locale: const Locale('zh', 'CN'),
        );
        await tester.pumpAndSettle();
        final pano = find.byKey(const ValueKey('panorama-frame'));
        expect(pano, findsOneWidget);
        expect(tester.getSize(pano).height, closeTo(280, 1.0));

        final tagChip = find.byType(TagChip).first;
        await tester.ensureVisible(tagChip);
        await tester.pumpAndSettle();
        final haptics = recordHaptics();
        await tester.tap(
          tagChip,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(haptics.roles, isEmpty);
        await tester.tap(find.text('屏蔽该标签'));
        await tester.pumpAndSettle();
        expect(find.text('已屏蔽'), findsOneWidget);

        await tester.tap(
          tagChip,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量屏蔽标签'));
        await tester.pumpAndSettle();
        expect(find.text('完成'), findsOneWidget);
        final pop = tester.widget<PopScope>(
          find.byWidgetPredicate((w) => w is PopScope).first,
        );
        expect(pop.canPop, isFalse);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(find.text('完成'), findsNothing);
      },
    );
  });
}
