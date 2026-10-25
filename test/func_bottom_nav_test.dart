import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

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
  setViewSize(tester, const Size(390, _screenHeight));
  final router = pixivRouter(location);
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      overrides: [...signedInAccountOverrides()],
      builder: promptHostBuilder,
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

    // A frame scrolling past 8 px down: the bar slides fully below the
    // screen edge — the layout never changes, the body was already painted
    // underneath.
    await tester.drag(_settingsList, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));

    // Scrolling back up restores it.
    await tester.drag(_settingsList, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });

  testWidgets('the bar follows a drag and settles at the nearer end', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final chrome = HomeShellChrome.of(
      tester.element(find.byType(MeDashboardPage)),
    );
    final extent = chrome.bottomBarExtent;
    final shownTop = tester.getTopLeft(nav).dy;
    double moved() => tester.getTopLeft(nav).dy - shownTop;

    // However slow the drag, the bar moves as far as the list does, and
    // the extent the hero clip and prompts read moves with it.
    final slow = await tester.startGesture(tester.getCenter(_settingsList));
    await slow.moveBy(const Offset(0, -20));
    await tester.pump();
    final start = moved();
    for (var i = 0; i < 10; i++) {
      await slow.moveBy(const Offset(0, -2));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(moved() - start, closeTo(20, 0.01));
    expect(
      chrome.bottomBarVisibleExtent.value,
      closeTo(extent - moved(), 0.01),
    );
    // Released short of half way, it comes back.
    await slow.up();
    await tester.pumpAndSettle();
    expect(moved(), closeTo(0, 0.5));

    // Past half way, it goes.
    final far = await tester.startGesture(tester.getCenter(_settingsList));
    await far.moveBy(const Offset(0, -20));
    await tester.pump();
    await far.moveBy(Offset(0, -extent * 0.6));
    await tester.pump();
    expect(moved(), lessThan(extent));
    await far.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
    expect(chrome.bottomBarVisibleExtent.value, 0);
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

  testWidgets('a wheel tick settles the way it went; other scrolls do not', (
    tester,
  ) async {
    await _pumpHome(tester);
    final nav = find.byType(FuncBottomNav);
    final shownTop = tester.getTopLeft(nav).dy;

    // Each tick is a scroll that rests at once, too short to pass half the
    // bar: it settles the way the page went.
    final center = tester.getCenter(_settingsList);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 5)),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, greaterThanOrEqualTo(_screenHeight));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -5)),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));

    // A programmatic scroll (scroll-to-top, a restored offset) is not
    // the user reading on.
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: _settingsList, matching: find.byType(Scrollable)),
        )
        .position;
    unawaited(
      position.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(tester.getTopLeft(nav).dy, closeTo(shownTop, 0.5));
  });
}
