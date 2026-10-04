import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/illust/ranking_repository.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';

const _account = Account(id: '100', userId: 100, name: 'tester');

Future<GoRouter> _pumpHome(
  WidgetTester tester, {
  String location = '/recommended',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  tester.view.physicalSize = const Size(390, 844);
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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return router;
}

String _path(GoRouter router) => router.routeInformationProvider.value.uri.path;

/// A committed sideways flick inside the visible branch page.
Future<void> _flingLeft(WidgetTester tester, Finder page) =>
    tester.fling(page, const Offset(-260, 0), 900);
Future<void> _flingRight(WidgetTester tester, Finder page) =>
    tester.fling(page, const Offset(260, 0), 900);

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

  testWidgets('a tab fling stays inside the tab strip at its edge', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    final page = find.byType(RecommendedHomePage);

    _tabController(tester, page).index = 3;
    await tester.pumpAndSettle();

    // Already on the last tab: the gesture stops at the strip edge and
    // never leaves the branch.
    await _flingLeft(tester, page);
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, page), 3);
    expect(_path(router), '/recommended');
  });

  testWidgets('a reverse fling from the first tab stays in its branch', (
    tester,
  ) async {
    final router = await _pumpHome(tester);
    final page = find.byType(RecommendedHomePage);
    await _flingRight(tester, page);
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, page), 0);
    expect(_path(router), '/recommended');
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

  testWidgets('the last ranking mode does not leave the branch', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/ranking');
    final page = find.byType(RankingPage);
    // Jump to the last mode — the next left fling must stop at the edge.
    _tabController(tester, page).index = RankingMode.values.length - 1;
    await tester.pumpAndSettle();

    await _flingLeft(tester, page);
    await tester.pumpAndSettle();
    expect(_tabIndex(tester, page), RankingMode.values.length - 1);
    expect(_path(router), '/ranking');
  });

  testWidgets('a page without tabs does not switch branches on a fling', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/search');
    await _flingLeft(tester, find.byType(SearchHomePage));
    await tester.pumpAndSettle();
    expect(_path(router), '/search');
  });

  testWidgets('the settings root does not switch branches on a fling', (
    tester,
  ) async {
    final router = await _pumpHome(tester, location: '/settings');
    await _flingRight(tester, find.byType(SettingsPage));
    await tester.pumpAndSettle();
    expect(_path(router), '/settings');
    await _flingLeft(tester, find.byType(SettingsPage));
    await tester.pumpAndSettle();
    expect(_path(router), '/settings');
  });
}
