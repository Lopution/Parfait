import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/platform/platform_caps.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/features/search/reverse_image_search_page.dart';
import 'package:pixiv_func/features/search/search_page.dart';
import 'package:pixiv_func/features/search/tag_search_page.dart';
import 'package:pixiv_func/features/settings/settings_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('shell owns the active tab and preserves branch stacks', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(StatefulNavigationShell), findsOneWidget);
    expect(find.byType(RecommendedHomePage), findsOneWidget);
    expect(find.byType(RankingPage, skipOffstage: false), findsNothing);
    expect(find.byType(NewPage, skipOffstage: false), findsNothing);
    expect(find.byType(SearchHomePage, skipOffstage: false), findsNothing);
    expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);

    await tester.tap(find.byIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/ranking');
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(NewPage, skipOffstage: false), findsNothing);

    await tester.tap(find.byIcon(AppIcons.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/recommended');
    expect(find.byType(RecommendedHomePage), findsOneWidget);
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('branch back is handled before the root exit coordinator', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The root exit coordinator is Android-only; the test host is
          // Linux, so inject Android caps for the back-press path.
          platformCapsProvider.overrideWithValue(
            const PlatformCaps(isAndroid: true),
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
    await tester.pump(const Duration(milliseconds: 100));

    unawaited(router.push('/recommended/history'));
    await tester.pump();
    expect(router.state.uri.path, '/recommended/history');

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(router.state.uri.path, '/recommended');
    expect(find.text('再按一次退出'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('再按一次退出'), findsOneWidget);
  });

  Future<GoRouter> pumpRouter(WidgetTester tester, String location) async {
    final router = createPixivRouter(initialLocation: location);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return router;
  }

  testWidgets('tag search stays on the stack it was opened from', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/ranking');
    expect(find.byType(RankingPage), findsOneWidget);

    unawaited(openTagSearch(tester.element(find.byType(RankingPage)), '猫'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/ranking/tag/%E7%8C%AB');
    expect(find.byType(TagSearchPage), findsOneWidget);
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
    expect(find.byType(SearchHomePage, skipOffstage: false), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/ranking');
    expect(find.byType(RankingPage), findsOneWidget);
  });

  testWidgets('bottom bar hides on pushed branch routes and returns at root', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(FuncBottomNav), findsOneWidget);

    unawaited(router.push('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(FuncBottomNav), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/recommended');
    expect(find.byType(FuncBottomNav), findsOneWidget);
  });

  testWidgets('settings pushes over the shell and returns to the tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = await pumpRouter(tester, '/recommended');

    // Gear in a tab AppBar pushes the root-level settings flow.
    unawaited(openSettings(tester.element(find.byType(RecommendedHomePage))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/settings');
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(FuncBottomNav), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/recommended');
    expect(find.byType(RecommendedHomePage), findsOneWidget);
  });

  testWidgets('/settings deep links still resolve as a root flow', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/settings/theme');
    expect(router.state.uri.path, '/settings/theme');
    expect(find.byType(SettingsPage), findsNothing);
  });

  testWidgets('wide layout uses a rail with settings as a peer entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = await pumpRouter(tester, '/recommended');

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(FuncBottomNav), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.settings_outlined),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/settings');
    expect(find.byType(SettingsPage), findsOneWidget);
  });

  testWidgets('detail pushed from the reverse-image page does not stack a '
      'second home shell', (tester) async {
    final router = await pumpRouter(tester, '/recommended');
    unawaited(router.push('/reverse-image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ReverseImageSearchPage), findsOneWidget);

    unawaited(
      openIllust(tester.element(find.byType(ReverseImageSearchPage)), 5),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/reverse-image/illust/5');
    expect(
      find.byType(StatefulNavigationShell, skipOffstage: false),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/reverse-image');
  });
}
