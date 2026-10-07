import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'helpers/test_preferences.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/features/bookmark/bookmark_tags_page.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/new/new_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/search/reverse_image_search_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/features/search/tag_search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';

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

  testWidgets('branch back returns to the recommended root', (tester) async {
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

    unawaited(router.push('/recommended/history'));
    await tester.pump();
    expect(router.state.uri.path, '/recommended/history');

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(router.state.uri.path, '/recommended');
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

  testWidgets('search input and results stay on the requesting stack', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/ranking');
    final ranking = find.byType(RankingPage);

    unawaited(openSearchInput(tester.element(ranking), initialKeyword: '猫'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/ranking/search/input');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/ranking');

    unawaited(
      openSearchResults(
        tester.element(find.byType(RankingPage)),
        const IllustSearchQuery(keyword: '猫'),
      ),
    );
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/ranking/search/results');
    expect(find.byType(SearchResultPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/ranking');
  });

  testWidgets('branch pushes are rejected outside the visible branch', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/recommended');
    expect(pushStaysInStack(router, '/recommended/illust/1'), isTrue);
    expect(pushStaysInStack(router, '/ranking/illust/1'), isFalse);
    expect(pushStaysInStack(router, '/downloads'), isTrue);

    router.go('/recommended/illust/1/viewer/0');
    await tester.pumpAndSettle();
    expect(pushStaysInStack(router, '/recommended/illust/2'), isFalse);
  });

  testWidgets('update prompt navigation uses one settings shell', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/me');
    goToAbout(router);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings/about');
    expect(
      find.byType(StatefulNavigationShell, skipOffstage: false),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings');
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
    final bar = find.byType(FuncBottomNav);
    expect(tester.getTopLeft(bar).dy, lessThan(844));

    unawaited(router.push('/recommended/history'));
    await tester.pump();
    // The covered report lands through the provider, which notifies on the
    // next frame — settle so the recheck frame and the slide both run.
    await tester.pumpAndSettle();

    // The bar is the shell-level sibling of the branch strip — a pushed
    // route slides it below the screen edge (covered provider), it does
    // not leave the tree.
    expect(bar, findsOneWidget);
    expect(tester.getTopLeft(bar).dy, greaterThanOrEqualTo(844));

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/recommended');
    expect(bar, findsOneWidget);
    expect(tester.getTopLeft(bar).dy, lessThan(844));
  });

  testWidgets('bottom bar stays hidden when a deep link builds the stack', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A cold start from a link builds root + pushed page in one go: no
    // didPushNext ever reaches the branch root.
    final router = createPixivRouter(initialLocation: '/recommended/history');
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
    await tester.pumpAndSettle();

    final bar = find.byType(FuncBottomNav);
    expect(bar, findsOneWidget);
    expect(tester.getTopLeft(bar).dy, greaterThanOrEqualTo(844));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/recommended');
    expect(tester.getTopLeft(bar).dy, lessThan(844));
  });

  testWidgets('settings pushes over the shell and returns to the tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = await pumpRouter(tester, '/recommended');

    // Settings is the fifth home destination: opening it switches the shell
    // branch, so its own bottom bar stays mounted like on any other tab.
    unawaited(openSettings(tester.element(find.byType(RecommendedHomePage))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/settings');
    expect(find.byType(MeDashboardPage), findsOneWidget);
    expect(find.byType(FuncBottomNav), findsOneWidget);

    // Branch switch back restores the recommended tab.
    router.go('/recommended');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/recommended');
    expect(find.byType(RecommendedHomePage), findsOneWidget);
  });

  testWidgets('openDownloadTasks lands on the root downloads route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = await pumpRouter(tester, '/recommended');

    // The submission SnackBar's 查看 action pushes the tasks page
    // directly, no matter which shell stack submitted the download.
    unawaited(
      openDownloadTasks(tester.element(find.byType(RecommendedHomePage))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router.state.uri.path, '/downloads');
    expect(find.byType(DownloadTasksPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended');
  });

  for (final origin in [
    '/recommended',
    '/ranking',
    '/new',
    '/search',
    '/settings',
    '/me',
    '/reverse-image',
    '/downloads',
  ]) {
    testWidgets('downloads return to $origin with one home shell', (
      tester,
    ) async {
      final overlay = ['/me', '/reverse-image', '/downloads'].contains(origin);
      final router = await pumpRouter(
        tester,
        overlay ? '/recommended' : origin,
      );
      if (overlay) {
        unawaited(router.push<void>(origin));
        await tester.pumpAndSettle();
      }
      unawaited(openDownloadTasks(tester.element(find.byType(Scaffold).last)));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/downloads');
      expect(find.byType(DownloadTasksPage), findsOneWidget);
      expect(
        find.byType(StatefulNavigationShell, skipOffstage: false),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, origin);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('openHistory stays on the stack it was called from', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/settings');
    expect(find.byType(MeDashboardPage), findsOneWidget);

    // The shared history route is mounted on every stack — the settings
    // branch gets /settings/history, returning to the Me tab on pop.
    unawaited(openHistory(tester.element(find.byType(MeDashboardPage))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/settings/history');
    expect(find.byType(HistoryPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/settings');
    expect(find.byType(MeDashboardPage), findsOneWidget);

    // From the /me overlay the same facade pushes the overlay-level
    // /me/history instead of bouncing to a branch.
    unawaited(router.push<void>('/me'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MePage), findsOneWidget);
    unawaited(openHistory(tester.element(find.byType(MePage))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/me/history');
    expect(find.byType(HistoryPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/me');
  });

  testWidgets('/settings/history/view no longer matches', (tester) async {
    final router = createPixivRouter(initialLocation: '/settings/history/view');
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
    // The retired settings-page subroute resolves to the router's
    // unmatched-path error page, not to a page.
    expect(find.byType(HistoryPage), findsNothing);
    expect(find.text('Page Not Found'), findsOneWidget);
  });

  testWidgets('every settings subroute returns to the Me root', (tester) async {
    final router = await pumpRouter(tester, '/settings');
    expect(find.byType(MeDashboardPage), findsOneWidget);

    for (final sub in [
      'account',
      'theme',
      'language',
      'translate',
      'motion',
      'browse',
      'muted',
      'network',
      'download',
      'backup',
      'about',
      'history',
    ]) {
      unawaited(router.push('/settings/$sub'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(router.state.uri.path, '/settings/$sub', reason: sub);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(router.state.uri.path, '/settings', reason: sub);
    }
  });

  testWidgets('pop slides the outgoing page as a snapshot texture', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/recommended');
    unawaited(openMe(tester.element(find.byType(RecommendedHomePage))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MePage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    // While the reverse animation runs, both leaving directions hand their
    // subtree to a SnapshotWidget so each frame blits a captured texture:
    // the popping route and the settled reveal it uncovers.
    await tester.pump(const Duration(milliseconds: 16));
    final snapshots = tester.widgetList<SnapshotWidget>(
      find.byType(SnapshotWidget, skipOffstage: false),
    );
    expect(
      snapshots.where((s) => s.controller.allowSnapshotting),
      hasLength(2),
    );
    // The live subtree stays mounted so a cancelled pop or route state
    // survives the snapshot window.
    expect(find.byType(MePage, skipOffstage: false), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/recommended');
    expect(find.byType(RecommendedHomePage), findsOneWidget);
  });

  testWidgets('/settings deep links still resolve as a root flow', (
    tester,
  ) async {
    final router = await pumpRouter(tester, '/settings/theme');
    expect(router.state.uri.path, '/settings/theme');
    expect(find.byType(MeDashboardPage), findsNothing);
  });

  testWidgets('bookmark tag route restores and writes its restrict query', (
    tester,
  ) async {
    final router = await pumpRouter(
      tester,
      '/recommended/bookmarks/tags?restrict=private',
    );
    expect(router.state.uri.queryParameters['restrict'], 'private');
    expect(find.byType(BookmarkTagsPage), findsOneWidget);
    int selectedTab() => tester
        .widget<TabBar>(
          find.descendant(
            of: find.byType(BookmarkTagsPage),
            matching: find.byType(TabBar),
          ),
        )
        .controller!
        .index;
    // Tab 0 is public, 1 private.
    expect(selectedTab(), 1);

    unawaited(
      openBookmarkTags(
        tester.element(find.byType(BookmarkTagsPage)),
        restrict: UserRestrict.public,
      ),
    );
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['restrict'], 'public');
    expect(selectedTab(), 0);
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
        matching: find.byIcon(Icons.person_outline),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.path, '/settings');
    expect(find.byType(MeDashboardPage), findsOneWidget);
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
