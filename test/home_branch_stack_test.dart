import 'dart:async';

import 'package:animations/animations.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/home_branch_stack.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/new/new_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
  double width = 390,
  bool reduceMotion = false,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = createPixivRouter(initialLocation: location);
  addTearDown(router.dispose);
  Widget app = MaterialApp.router(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    routerConfig: router,
  );
  if (reduceMotion) {
    app = MotionScope(reduce: true, child: app);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...accountProviderOverrides(
          credentialStore: FakeCredentialStore(
            values: const {
              '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
            },
          ),
          metadataRepository: FakeAccountMetadataRepository(
            accounts: const [_account],
            currentId: '100',
          ),
        ),
      ],
      child: app,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

String _path(GoRouter router) => router.routeInformationProvider.value.uri.path;

Finder _barIcon(IconData icon) => find.descendant(
  of: find.byType(FuncShellBottomNav),
  matching: find.byIcon(icon),
);

List<int> _recordReTaps(WidgetTester tester, Finder page) {
  final channel = HomeBranchStack.reTapOf(tester.element(page))!;
  final events = <int>[];
  channel.addListener(() => events.add(channel.branch));
  return events;
}

/// The IgnorePointer HomeBranchStack puts around each branch child — the
/// one whose own child is the branch's ExcludeSemantics, not any pointer
/// guard a route inside the branch Navigator may add.
IgnorePointer _branchPointer(WidgetTester tester, Finder page) => tester
    .widgetList<IgnorePointer>(
      find.ancestor(of: page, matching: find.byType(IgnorePointer)),
    )
    .singleWhere((w) => w.child is ExcludeSemantics);

ExcludeSemantics _branchSemantics(WidgetTester tester, Finder page) => tester
    .widgetList<ExcludeSemantics>(
      find.ancestor(of: page, matching: find.byType(ExcludeSemantics)),
    )
    .singleWhere((w) => w.child is BranchActivityScope);

bool _branchActive(WidgetTester tester, Finder page) => tester
    .widget<BranchActivityScope>(
      find.ancestor(of: page, matching: find.byType(BranchActivityScope)),
    )
    .active;

/// Drives the shell's shared tap entry the way FuncShellBottomNav does —
/// needed while a pushed route covers the current branch root, when the
/// bar has slid off screen and cannot be tapped.
void _select(WidgetTester tester, int index) => tester
    .widget<FuncShellBottomNav>(find.byType(FuncShellBottomNav))
    .onSelected(index);

void main() {
  testWidgets('a bar tap fades the outgoing branch out and the new one in', (
    tester,
  ) async {
    await _pumpHome(tester);
    expect(find.byType(RankingPage), findsNothing);

    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    // Mid-flight both branches are on stage — the fade-through pair —
    // but only the incoming one is hittable, has semantics and is marked
    // active for predictive back.
    await tester.pump(const Duration(milliseconds: 150));
    final recommended = find.byType(RecommendedHomePage);
    final ranking = find.byType(RankingPage);
    expect(recommended, findsOneWidget);
    expect(ranking, findsOneWidget);
    expect(_branchPointer(tester, recommended).ignoring, isTrue);
    expect(_branchPointer(tester, ranking).ignoring, isFalse);
    expect(_branchSemantics(tester, recommended).excluding, isTrue);
    expect(_branchSemantics(tester, ranking).excluding, isFalse);
    expect(_branchActive(tester, recommended), isFalse);
    expect(_branchActive(tester, ranking), isTrue);

    // Settled: the outgoing branch leaves the stage entirely.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(RecommendedHomePage), findsNothing);
    expect(
      find.byType(RecommendedHomePage, skipOffstage: false),
      findsOneWidget,
    );
    expect(ranking, findsOneWidget);
  });

  testWidgets('both branches stay frozen textures until the switch lands', (
    tester,
  ) async {
    await _pumpHome(tester);
    // Still found once the switch has put it offstage.
    final recommended = find.byType(RecommendedHomePage, skipOffstage: false);
    bool tickersOn(Finder page) =>
        TickerMode.valuesOf(tester.element(page)).enabled;
    // The branch's own snapshot: the outermost below the fade-through, above
    // the route snapshots inside the branch Navigator.
    bool snapshotting() => tester
        .widget<SnapshotWidget>(
          find
              .ancestor(
                of: recommended,
                matching: find.descendant(
                  of: find.byType(FadeThroughTransition, skipOffstage: false),
                  matching: find.byType(SnapshotWidget, skipOffstage: false),
                  skipOffstage: false,
                ),
              )
              .last,
        )
        .controller
        .allowSnapshotting;
    expect(tickersOn(recommended), isTrue);
    expect(snapshotting(), isFalse);

    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final ranking = find.byType(RankingPage);
    expect(tickersOn(recommended), isFalse);
    expect(tickersOn(ranking), isFalse);
    expect(snapshotting(), isTrue);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tickersOn(ranking), isTrue);
    expect(snapshotting(), isFalse);
  });

  testWidgets('a switch interrupting another keeps its outgoing branch', (
    tester,
  ) async {
    await _pumpHome(tester);
    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _select(tester, 4);
    await tester.pump();
    // The first switch's cancellation must not end the second one early.
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(RankingPage), findsOneWidget);
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(RankingPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('reduced motion switches branches within a frame', (
    tester,
  ) async {
    await _pumpHome(tester, reduceMotion: true);

    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    expect(find.byType(RecommendedHomePage), findsNothing);
    expect(find.byType(RankingPage), findsOneWidget);
  });

  testWidgets('each branch keeps its stack and scroll position', (
    tester,
  ) async {
    final router = await _pumpHome(tester);

    // A route pushed inside the recommended branch survives switches.
    unawaited(router.push<void>('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HistoryPage), findsOneWidget);

    _select(tester, 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    // Scroll the settings list, then leave again.
    final list = find.descendant(
      of: find.byType(SettingsPage),
      matching: find.byType(ListView),
    );
    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(position, greaterThan(0));

    // Back to recommended: the pushed page is still on top of its stack.
    _select(tester, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(HistoryPage), findsOneWidget);

    // And the settings list kept its scroll offset.
    _select(tester, 4);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.state<ScrollableState>(scrollable).position.pixels, position);
  });

  testWidgets('cold start builds no unvisited branch', (tester) async {
    await _pumpHome(tester);
    for (final type in [RankingPage, NewPage, SearchHomePage, SettingsPage]) {
      expect(find.byType(type, skipOffstage: false), findsNothing);
    }

    await tester.tap(_barIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(RankingPage), findsOneWidget);
  });

  group('re-tap channel', () {
    testWidgets('a same-destination tap emits one event per tap', (
      tester,
    ) async {
      await _pumpHome(tester);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      await tester.tap(_barIcon(AppIcons.home));
      await tester.pump();
      expect(events, [0]);

      // A repeat fires again — the event is an edge, not a state.
      await tester.tap(_barIcon(AppIcons.home));
      await tester.pump();
      expect(events, [0, 0]);
    });

    testWidgets('a re-tap pops the branch stack back to its root', (
      tester,
    ) async {
      final router = await _pumpHome(tester);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      // Imperative pushes do not update the URL
      // (GoRouter.optionURLReflectsImperativeAPIs stays off), so the
      // pushed route is asserted through the widget tree instead of
      // routeInformationProvider. The history page keeps a spinner alive,
      // so bounded pumps drive the transition — never pumpAndSettle here.
      unawaited(router.push<void>('/recommended/history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HistoryPage), findsOneWidget);

      // The bar slides away while a pushed route covers the root, so the
      // tap arrives at the stack the same way FuncShellBottomNav sends it.
      _select(tester, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(RecommendedHomePage), findsOneWidget);
      expect(events, [0]);
    });

    testWidgets('a different-destination tap does not emit', (tester) async {
      await _pumpHome(tester);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      await tester.tap(_barIcon(AppIcons.search));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(events, isEmpty);
    });

    testWidgets('a programmatic branch switch does not emit', (tester) async {
      final router = await _pumpHome(tester, location: '/search');
      final events = _recordReTaps(tester, find.byType(SearchHomePage));

      // A deep link moves the shell — didUpdateWidget fades without any
      // re-tap.
      router.go('/recommended');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(_path(router), '/recommended');
      expect(events, isEmpty);

      // Back again is silent too.
      router.go('/search');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(_path(router), '/search');
      expect(events, isEmpty);
    });
  });

  group('NavigationRail shares the bar action entry', () {
    // Wide surfaces swap the bottom bar for a NavigationRail; both
    // controls funnel into HomeBranchStack's select, so each check mirrors
    // a bar case above.
    testWidgets('a different-destination rail tap fades over and does '
        'not emit', (tester) async {
      final router = await _pumpHome(tester, width: 900);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(FuncShellBottomNav), findsNothing);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(AppIcons.ranking),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(_path(router), '/ranking');
      expect(find.byType(RankingPage), findsOneWidget);
      expect(events, isEmpty);
    });

    testWidgets('a same-destination rail tap pops the branch stack and '
        'emits re-tap', (tester) async {
      final router = await _pumpHome(tester, width: 900);
      final events = _recordReTaps(tester, find.byType(RecommendedHomePage));

      unawaited(router.push<void>('/recommended/history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HistoryPage), findsOneWidget);

      // The rail stays mounted while a pushed route covers the branch —
      // a tap here used to die on goBranch's same-index no-op. Through
      // the shared entry it is the bar's re-tap: pop to root + emit.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(AppIcons.home),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byType(HistoryPage), findsNothing);
      expect(find.byType(RecommendedHomePage), findsOneWidget);
      expect(events, [0]);
    });
  });

  group('touch exploration', () {
    final settingsList = find.descendant(
      of: find.byType(SettingsPage),
      matching: find.byType(ListView),
    );

    testWidgets('the bottom bar stays on screen while scrolling', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pumpHome(tester, location: '/settings');
      final nav = find.byType(FuncBottomNav);
      final shownTop = tester.getTopLeft(nav).dy;

      // A TalkBack user cannot find a bar that slid off screen, so the
      // scroll-hide path is parked while touch exploration is on.
      await tester.drag(settingsList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
    });

    testWidgets('starting touch exploration brings a hidden bar back', (
      tester,
    ) async {
      await _pumpHome(tester, location: '/settings');
      final nav = find.byType(FuncBottomNav);
      final shownTop = tester.getTopLeft(nav).dy;

      // Hide with a real scroll first.
      await tester.drag(settingsList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(844));

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
    });

    testWidgets('semantics alone does not pin the bar', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpHome(tester, location: '/settings');
      final nav = find.byType(FuncBottomNav);

      // Services that only open the semantics tree do not set
      // accessibleNavigation — the bar keeps its hide-on-scroll.
      await tester.drag(settingsList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(844));
      handle.dispose();
    });
  });
}
