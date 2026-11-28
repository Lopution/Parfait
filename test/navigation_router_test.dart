import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/features/novel/novel_page.dart';
import 'package:parfait/features/bookmark/bookmark_tags_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/features/search/tag_search_page.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/features/home/home_page.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/arrangement.dart';
import 'helpers/localized_app.dart';
import 'helpers/settings_world.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';

/// The shell's own bar, while it is on stage.
final _shellBar = find.descendant(
  of: find.byType(FuncShellBottomNav),
  matching: find.byType(FuncBottomNav),
);

/// The copy a covered branch root draws under the routes above it.
final _rootCopy = find.descendant(
  of: find.byType(BranchRootScaffold),
  matching: find.byType(FuncBottomNav),
);

void main() {
  // Each way the start page stops being where the hint was shown.
  final exitInterruptions =
      <String, Future<void> Function(WidgetTester, GoRouter)>{
        'the window closes': (tester, router) async {
          await tester.pump(homeExitWindow);
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('再按一次退出'), findsNothing, reason: 'hint goes too');
        },
        'a page opens': (tester, router) async {
          unawaited(router.push('/recommended/history'));
          await tester.pump(const Duration(milliseconds: 600));
          await tester.binding.handlePopRoute();
          await tester.pump(const Duration(milliseconds: 600));
        },
        'an overlay opens': (tester, router) async {
          unawaited(router.push('/reverse-image'));
          await tester.pump(const Duration(milliseconds: 600));
          await tester.binding.handlePopRoute();
          await tester.pump(const Duration(milliseconds: 600));
        },
        'the app leaves the foreground': (tester, router) async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('再按一次退出'), findsNothing, reason: 'not left up');
        },
        'the branch changes': (tester, router) async {
          router.go('/ranking');
          await tester.pump(const Duration(milliseconds: 600));
          await tester.binding.handlePopRoute();
          await tester.pump(const Duration(milliseconds: 600));
          expect(router.state.uri.path, '/recommended');
        },
      };
  testWidgets(
    'a second back at the start exits; interruptions reset the hint',
    (tester) async {
      final exits = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') exits.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final router = pixivRouter('/recommended');
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          // The double back is Android's; the test host is Linux.
          overrides: [
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isAndroid: true),
            ),
          ],
          builder: promptHostBuilder,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      Future<void> back() async {
        await tester.binding.handlePopRoute();
        await tester.pump();
      }

      await back();
      expect(find.text('再按一次退出'), findsOneWidget);
      expect(exits, isEmpty);
      await back();
      expect(exits, hasLength(1));

      for (final MapEntry(key: name, value: interrupt)
          in exitInterruptions.entries) {
        await back();
        await interrupt(tester, router);
        await back();
        expect(find.text('再按一次退出'), findsOneWidget, reason: 'after $name');
        expect(exits, hasLength(1), reason: 'after $name a back starts over');
        // Expire the hint window so the next interruption starts cleanly.
        await tester.pump(homeExitWindow);
        await tester.pump(const Duration(milliseconds: 400));
      }
    },
  );

  Future<GoRouter> pumpRouter(
    WidgetTester tester,
    String location, {
    List<Override> overrides = const [],
  }) async {
    final router = pixivRouter(location);
    await tester.pumpWidget(localizedRouterApp(router, overrides: overrides));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return router;
  }

  testWidgets('a novel opened at a page carries it in memory, not the '
      'location', (tester) async {
    final router = await pumpRouter(tester, '/ranking');
    unawaited(
      openNovel(tester.element(find.byType(RankingPage)), 5, atPixivPage: 3),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.uri.toString(), '/ranking/novel/5');
    NovelPage page() => tester.widget(find.byType(NovelPage));
    expect(page().atPixivPage, 3);

    // The same location without the list's word opens at the saved place.
    router.go('/ranking/novel/6');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(page().atPixivPage, isNull);

    // Stepping between chapters with replaceCurrent keeps a single reader on
    // the stack so one pop returns straight to the reading entry.
    router.go('/ranking');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    unawaited(openNovel(tester.element(find.byType(RankingPage)), 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    unawaited(
      openNovel(
        tester.element(find.byType(NovelPage)),
        6,
        replaceCurrent: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    unawaited(
      openNovel(
        tester.element(find.byType(NovelPage)),
        7,
        replaceCurrent: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.toString(), '/ranking/novel/7');
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(router.state.uri.toString(), '/ranking');
  });

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
    expect(find.byType(SearchHomePage), findsNothing);

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

  testWidgets('a pushed branch route covers the bar and hands it back', (
    tester,
  ) async {
    setViewSize(tester, const Size(390, 844));
    final router = pixivRouter('/recommended');

    await tester.pumpWidget(ProviderScope(child: localizedRouterApp(router)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_shellBar, findsOneWidget);
    expect(_rootCopy, findsNothing);
    final resting = tester.getRect(_shellBar);
    expect(resting.bottom, 844);

    // From the push on, the root page draws the bar where the shell bar
    // was, under the incoming page; the shell bar steps aside.
    unawaited(router.push('/recommended/history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_shellBar, findsNothing);
    expect(tester.getRect(_rootCopy).top, resting.top);
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-pop the page uncovering the root uncovers its copy of the bar,
    // which moves along with the root page.
    expect(_shellBar, findsNothing);
    expect(tester.getRect(_rootCopy).top, resting.top);
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/recommended');
    expect(_rootCopy, findsNothing);
    expect(tester.getRect(_shellBar), resting);
  });

  // Representative origins across the three stack classes: shell branch root,
  // overlay route, and self-origin.
  testWidgets(
    'downloads return to branch, overlay, and self origins with one home shell',
    (tester) async {
      setViewSize(tester, const Size(390, 844));
      setDisplaySize(tester, const Size(390, 844));
      for (final origin in const ['/recommended', '/me', '/downloads']) {
        final overlay = origin != '/recommended';
        final router = await pumpRouter(
          tester,
          overlay ? '/recommended' : origin,
        );
        if (overlay) {
          unawaited(router.push<void>(origin));
          await tester.pumpAndSettle();
        }
        unawaited(
          openDownloadTasks(tester.element(find.byType(Scaffold).last)),
        );
        await tester.pumpAndSettle();
        expect(router.state.uri.path, '/downloads', reason: origin);
        expect(find.byType(DownloadTasksPage), findsOneWidget, reason: origin);
        expect(
          find.byType(StatefulNavigationShell, skipOffstage: false),
          findsOneWidget,
          reason: origin,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(router.state.uri.path, origin, reason: origin);
        expect(tester.takeException(), isNull, reason: origin);
      }
    },
  );

  testWidgets('bookmark tag route restores and writes its kind and restrict '
      'query', (tester) async {
    // An older location names no kind: illustrations.
    final router = await pumpRouter(
      tester,
      '/recommended/bookmarks/tags?restrict=private',
    );
    expect(router.state.uri.queryParameters['restrict'], 'private');
    expect(find.byType(BookmarkTagsPage), findsOneWidget);
    BookmarkTagsPage page() => tester.widget(find.byType(BookmarkTagsPage));
    expect(page().kind, BookmarkEntityType.illust);
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
        kind: BookmarkEntityType.novel,
        restrict: UserRestrict.public,
      ),
    );
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['restrict'], 'public');
    expect(router.state.uri.queryParameters['kind'], 'novel');
    expect(selectedTab(), 0);
    expect(page().kind, BookmarkEntityType.novel);
  });

  group('bottom bar arrangement', () {
    const shown = [
      HomeDestination.ranking,
      HomeDestination.newWorks,
      HomeDestination.me,
    ];
    Future<AppSettings> stored() => storedSettings().load();

    Future<GoRouter> pumpBar(WidgetTester tester, String location) async {
      setViewSize(tester, const Size(390, 844));
      await seedSettings(
        baseTestSettings().copyWith(
          homeArrangement: const Arrangement(
            shown: shown,
            hidden: [HomeDestination.recommended, HomeDestination.search],
          ).toEntries((d) => d.name),
          homeStartPage: homeStartLastUsed,
          lastHomeDestination: HomeDestination.newWorks.name,
        ),
      );
      final router = pixivRouter(location);
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          overrides: const [],
          builder: promptHostBuilder,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return router;
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Finder onBar(IconData icon) =>
        find.descendant(of: _shellBar, matching: find.byIcon(icon));

    testWidgets('a rearranged bar starts, goes back and reaches hidden pages', (
      tester,
    ) async {
      final router = await pumpBar(tester, '/settings');
      router.go('/');
      await settle(tester);
      expect(router.state.uri.path, '/new');
      expect(onBar(AppIcons.home), findsNothing);
      expect(onBar(AppIcons.search), findsNothing);
      final xs = [
        for (final d in shown)
          tester
              .getCenter(
                onBar(
                  d == HomeDestination.newWorks
                      ? homeDestinationSelectedIcon(d)
                      : homeDestinationIcon(d),
                ),
              )
              .dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()));

      await tester.tap(onBar(AppIcons.user));
      await settle(tester);
      final recommended = find.descendant(
        of: find.byType(MeDashboardPage),
        matching: find.byIcon(AppIcons.home),
      );
      await tester.ensureVisible(recommended);
      await tester.tap(recommended);
      await settle(tester);
      expect(router.state.uri.path, '/recommended');
      expect(tester.widget<FuncBottomNav>(_shellBar).selectedIndex, isNull);

      await tester.tap(
        find.descendant(
          of: find.byType(RecommendedHomePage),
          matching: find.byIcon(AppIcons.search),
        ),
      );
      await settle(tester);
      expect(router.state.uri.path, '/search');

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(router.state.uri.path, '/new', reason: 'back to the start page');

      router.go('/ranking');
      await settle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect((await stored()).lastHomeDestination, 'ranking');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(router.state.uri.path, '/new', reason: 'where this run opened');
    });
  });
}
