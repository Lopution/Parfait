import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/widgets/tab_swipe_switcher.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/touch.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  setViewSize(tester, const Size(390, 844));
  final router = pixivRouter(location);
  await tester.pumpWidget(
    localizedRouterApp(router, overrides: [...signedInAccountOverrides()]),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

String _path(GoRouter router) => router.routeInformationProvider.value.uri.path;

/// A committed sideways flick inside the visible branch page.
Future<void> _flingLeft(WidgetTester tester, Finder page) =>
    tester.fling(page, const Offset(-260, 0), 900);

TabController _tabController(WidgetTester tester, Finder page) => tester
    .widget<TabBar>(find.descendant(of: page, matching: find.byType(TabBar)))
    .controller!;

int _tabIndex(WidgetTester tester, Finder page) =>
    _tabController(tester, page).index;

void main() {
  testWidgets('sideways flings step the page\'s own top tabs', (tester) async {
    final router = await _pumpHome(tester);
    final page = find.byType(RecommendedHomePage);
    expect(_tabIndex(tester, page), 0);

    // Recommended has four tabs — each fling advances one.
    for (var i = 1; i <= 3; i++) {
      await _flingLeft(tester, page);
      await tester.pumpAndSettle();
      expect(_tabIndex(tester, page), i);
      expect(_path(router), '/recommended');
    }
  });

  testWidgets('a vertical fling never switches tabs', (tester) async {
    final router = await _pumpHome(tester);
    await tester.fling(
      find.byType(RecommendedHomePage),
      const Offset(0, -300),
      1200,
    );
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, find.byType(RecommendedHomePage)), 0);
    expect(_path(router), '/recommended');
  });

  // The tabs take only a drag at least twice as horizontal as vertical, as
  // Android's ViewPager does; a swipe leaning further scrolls the feed.
  for (final (degrees, switches) in [(20.0, true), (35.0, false)]) {
    testWidgets('a swipe ${degrees.round()}° off horizontal '
        '${switches ? 'moves the tabs' : 'leaves the tabs'}', (tester) async {
      final controller = TabController(length: 2, vsync: const TestVSync());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TabSwipeSwitcher(
            tabController: controller,
            child: ListView(
              children: [
                for (var i = 0; i < 30; i++) const SizedBox(height: 80),
              ],
            ),
          ),
        ),
      );
      setDeviceTouchSlop(tester);
      await tester.pump();

      final gesture = await dragLeftUp(
        tester,
        tester.getCenter(find.byType(ListView)),
        degrees: degrees,
      );
      expect(controller.offset > 0, switches);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('a slow but deliberate sideways drag still switches', (
    tester,
  ) async {
    await _pumpHome(tester);
    // Distance past a quarter of the screen commits even without a fling.
    await tester.drag(
      find.byType(RecommendedHomePage),
      const Offset(-160, 0),
      touchSlopX: 18,
    );
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, find.byType(RecommendedHomePage)), 1);
  });

  testWidgets('a new tab list drops the spring-back of the old one', (
    tester,
  ) async {
    const vsync = TestVSync();
    final long = TabController(length: 4, vsync: vsync, initialIndex: 3);
    final short = TabController(length: 3, vsync: vsync, initialIndex: 1);
    final current = ValueNotifier(long);
    addTearDown(long.dispose);
    addTearDown(short.dispose);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: current,
          builder: (context, controller, _) => TabSwipeSwitcher(
            tabController: controller,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    // A short drag springs back to the last tab; the list shrinks mid-way.
    await tester.drag(
      find.byType(TabSwipeSwitcher),
      const Offset(40, 0),
      touchSlopX: 18,
    );
    await tester.pump(const Duration(milliseconds: 16));
    current.value = short;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((short.index, short.offset), (1, 0.0));
  });
}
