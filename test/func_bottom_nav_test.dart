import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

/// A split-screen phone height: the "me" dashboard at the root of the
/// settings branch fits a full phone screen and only scrolls on a short
/// one.
const _screenHeight = 480.0;

/// Pumps the real home shell — the bottom bar now lives one layer up in
/// [HomeBranchStack] (a sibling of the branch stack), so scroll-hide
/// behaviour can only be exercised through a real branch Navigator.
Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/settings',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  tester.view.physicalSize = const Size(390, _screenHeight);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = createPixivRouter(initialLocation: location);
  addTearDown(router.dispose);
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
      child: MaterialApp.router(
        builder: promptHostBuilder,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  // Settle the entry transition: a half-run ModalRoute keeps its modal
  // barrier hit-testable, which swallows drags aimed at the page.
  await tester.pumpAndSettle();
  // A prior testWidgets in the same process can leave a pushed route in
  // the branch Navigator (e.g. /settings/translate). Force the branch
  // back to its root so the harness always starts from a clean stack.
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

Finder get _settingsList => find.descendant(
  of: find.byType(MeDashboardPage),
  matching: find.byType(ListView),
);

void main() {
  testWidgets('shell bar collapses on scroll down and returns on scroll up', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;
    expect(shownTop, lessThan(_screenHeight));

    // Scroll down past the touch-slop threshold: the bar slides fully below
    // the screen edge — the layout never changes, the body was already
    // painted underneath.
    await tester.drag(_settingsList, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));

    // Scrolling back up restores it.
    await tester.drag(_settingsList, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });

  testWidgets('bar collapses mid-drag, not on release', (tester) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;

    // Finger still down: crossing the slop mid-drag must already slide the
    // bar out — waiting for release would mean only the ballistic phase
    // counts. Time is advanced in frames: a single large pump step does
    // not tick controllers while a pointer is held.
    final gesture = await tester.startGesture(tester.getCenter(_settingsList));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -120));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.getTopLeft(nav).dy, greaterThan(shownTop));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
  });

  testWidgets('a continuous drag slides the bar out under the finger', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);

    // Every frame's move crosses the slop and asks for the hide again; the
    // slide must keep its own clock instead of restarting on each ask, so
    // it finishes within a drag that outlasts MotionTokens.navBarHide.
    final gesture = await tester.startGesture(tester.getCenter(_settingsList));
    await gesture.moveBy(const Offset(0, -20));
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('edge bounce never toggles the bar', (tester) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;
    final list = _settingsList;

    // Top edge: pull down into overscroll and release. The spring-back
    // replays positive deltas which must not hide the bar.
    var gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));

    // Hide the bar with a real scroll, land at the bottom edge.
    await tester.drag(list, const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));

    // Bottom edge: pull past the end and release. The spring-back deltas
    // must not resurrect the bar.
    gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
  });

  testWidgets('the shell bar publishes its live visible extent', (
    tester,
  ) async {
    await _pumpHome(tester);
    final chrome = HomeShellChrome.of(
      tester.element(find.byType(MeDashboardPage)),
    );
    final extent = chrome.bottomBarExtent;
    expect(extent, greaterThan(0));
    expect(chrome.bottomBarVisibleExtent.value, closeTo(extent, 0.001));

    // Scrolling down slides the bar out; the published extent shrinks in
    // step with the animation instead of snapping.
    await tester.drag(_settingsList, const Offset(0, -200));
    var sawPartial = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final v = chrome.bottomBarVisibleExtent.value;
      if (v == 0) break;
      if (v < extent) sawPartial = true;
    }
    expect(sawPartial, isTrue);
    await tester.pumpAndSettle();
    expect(chrome.bottomBarVisibleExtent.value, 0);

    await tester.drag(_settingsList, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(chrome.bottomBarVisibleExtent.value, closeTo(extent, 0.001));
  });

  testWidgets('short scrolls below the slop keep the bar expanded', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;

    // Alternating sub-slop deltas never cross the accumulated threshold.
    // They must arrive as wheel ticks: a touch drag small enough to stay
    // under the bar's ~8px slop can never claim the Scrollable's own 18px
    // slop, and a release inside slop lands as a *tap* on whatever tile
    // sits under the pointer — pushing a route and legitimately hiding
    // the bar. PointerScrollEvent applies its delta directly, no arena.
    final center = tester.getCenter(_settingsList);
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 5)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, -5)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });
}
