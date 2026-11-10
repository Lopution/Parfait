import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/app_breakpoints.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';

import 'review_support.dart';

/// The five home destinations, their in-page tabs and feed states.
void main() {
  testShot(
    'home/recommended',
    location: '/recommended',
    variants: {...ShotVariant.values},
  );
  // The PC shell: the rail collapsed under its menu button, then opened
  // into the labelled panel. A phone keeps its bottom bar. The review
  // device is Android, where the interface form ignores the setting, so
  // these scenes replace both the framework platform and the platform
  // caps with Windows before the app builds.
  for (final open in [false, true]) {
    testShot(
      'home/recommended-pc${open ? '-open' : ''}',
      location: '/recommended',
      platform: TargetPlatform.windows,
      setup: const ReviewSetup(platformCaps: PlatformCaps(isWindows: true)),
      variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
      before: (tester, router) async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await tester.runAsync(() async {
          final settings = container.read(settingsProvider.notifier);
          await settings.setInterfaceForm(InterfaceForm.pc);
          await settings.setRailExpanded(open);
        });
        await tester.pumpAndSettle();
        // The expected form comes from the preset device, not the tree:
        // a phone display is a phone whatever the platform; a desk-sized
        // one on Windows is the PC shell. The rail follows the preset
        // window width, so an unexpected phone fallback cannot pass.
        final display = reviewDevice.displaySize;
        final expectedForm = AppBreakpoints.isPhoneDisplay(display)
            ? FormFactor.phone
            : FormFactor.pc;
        expect(
          FormFactor.of(tester.element(find.byType(Scaffold).first)),
          expectedForm,
        );
        if (!expectedForm.hasRail(
          (reviewDevice.physicalSize / reviewDevice.dpr).width,
        )) {
          expect(find.byType(ShellRail), findsNothing);
        } else {
          expect(
            tester.getSize(find.byType(ShellRail)).width,
            open ? ShellRail.expandedWidth : ShellRail.width,
          );
        }
      },
    );
  }
  // The grid at the other two densities (FEED-19).
  for (final density in [FeedDensity.compact, FeedDensity.comfortable]) {
    testShot(
      'home/recommended-${density.name}',
      location: '/recommended',
      setup: ReviewSetup(
        overrides: [feedDensityProvider.overrideWithValue(density)],
      ),
    );
  }
  testShot('home/recommended-manga', location: '/recommended?type=manga');
  testShot('home/recommended-novel', location: '/recommended?type=novel');
  testShot('home/recommended-user', location: '/recommended?type=user');
  testShot(
    'home/ranking',
    location: '/ranking',
    variants: {
      ShotVariant.dark,
      ShotVariant.largeText,
      ShotVariant.ru,
      ShotVariant.ja,
    },
  );
  testShot('home/ranking-week', location: '/ranking?mode=week');
  testShot('home/ranking-male', location: '/ranking?mode=dayMale');
  // The category sheet, browsing and editing.
  Future<void> openCategories(WidgetTester tester, _) async {
    await tester.tap(find.byIcon(Icons.grid_view_outlined));
    await tester.pumpAndSettle();
  }

  testShot(
    'home/ranking-categories',
    location: '/ranking?mode=week',
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
    before: openCategories,
  );
  testShot(
    'home/ranking-categories-edit',
    location: '/ranking',
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
    before: (tester, router) async {
      await openCategories(tester, router);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byIcon(Icons.edit_outlined),
        ),
      );
      await tester.pumpAndSettle();
    },
  );
  testShot('home/new', location: '/new');
  testShot('home/new-all', location: '/new?scope=all');
  testShot('home/new-mypixiv', location: '/new?scope=mypixiv');
  testShot(
    'home/search',
    location: '/search',
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
  );
  testShot(
    'home/settings',
    location: '/settings',
    setup: ReviewSetup(history: reviewHistory()),
    variants: {...ShotVariant.values},
  );
  // The Me page's end: the settings and about rows under the list.
  testShot(
    'home/settings-end',
    location: '/settings',
    setup: ReviewSetup(history: reviewHistory()),
    before: (tester, router) async {
      await tester.drag(find.byType(ListView).first, const Offset(0, -800));
    },
  );
  testShot(
    'home/recommended-semantics',
    location: '/recommended',
    variants: const {},
    semanticsDebugger: true,
  );

  testShot(
    'home/recommended-loading',
    location: '/recommended',
    state: 'loading',
    setup: ReviewSetup(api: {'/v1/illust/recommended': reviewLoading()}),
  );
  testShot(
    'home/recommended-empty',
    location: '/recommended',
    state: 'empty',
    setup: ReviewSetup(api: {'/v1/illust/recommended': reviewEmpty('illusts')}),
    variants: {ShotVariant.dark, ...overflowVariants},
  );
  testShot(
    'home/recommended-error',
    location: '/recommended',
    state: 'error',
    setup: ReviewSetup(api: {'/v1/illust/recommended': reviewError()}),
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.talkBack},
  );
  testShot(
    'home/ranking-empty',
    location: '/ranking',
    state: 'empty',
    setup: ReviewSetup(api: {'/v1/illust/ranking': reviewEmpty('illusts')}),
  );
  testShot(
    'home/new-error',
    location: '/new',
    state: 'error',
    setup: ReviewSetup(api: {'/v2/illust/follow': reviewError()}),
  );
}
