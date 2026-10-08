import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/search_world.dart';
import 'helpers/test_preferences.dart';

Future<GoRouter> _pumpRouter(
  WidgetTester tester, {
  required String initialLocation,
  Locale locale = const Locale('zh', 'CN'),
}) async {
  // The input page reads the search history from preferences.
  installMemoryPreferences();
  final router = createPixivRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);
  // Wide surface: the whole chip row fits, so every chip is on screen.
  tester.view.physicalSize = const Size(1400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        searchRepositoryProvider.overrideWithValue(FakeSearchRepository()),
      ],
      child: MaterialApp.router(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
  return router;
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

void main() {
  testWidgets('each type switches to its own session filter set', (
    tester,
  ) async {
    final router = await _pumpRouter(
      tester,
      initialLocation: '/search/input?q=cat&type=illust',
    );
    unawaited(
      router.push('/search/results?q=cat&type=illust&sort=date_asc&bmin=100'),
    );
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(SearchResultPage));
    expect(find.text('收藏数 100 以上'), findsOneWidget);

    await tester.tap(_tab('用户'));
    await tester.pumpAndSettle();
    final params = router.state.uri.queryParameters;
    expect(params['type'], 'user');
    expect(params['q'], 'cat');
    // A user search has no filters — the URL carries none.
    expect(params.containsKey('sort'), isFalse);
    expect(params.containsKey('bmin'), isFalse);
    expect(find.text('收藏数 100 以上'), findsNothing);
    expect(find.byTooltip('筛选'), findsNothing);
    // The route was replaced in place: same page state, no new page.
    expect(tester.state(find.byType(SearchResultPage)), same(state));

    // Back on the artwork tab the session's illust set is still there.
    await tester.tap(_tab('插画 & 漫画'));
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['type'], 'illust');
    expect(router.state.uri.queryParameters['bmin'], '100');
    expect(find.text('收藏数 100 以上'), findsOneWidget);

    // The novel tab gets its own set — the persisted novel defaults, not
    // the illust session edits.
    await tester.tap(_tab('小说'));
    await tester.pumpAndSettle();
    final novelParams = router.state.uri.queryParameters;
    expect(novelParams['type'], 'novel');
    expect(novelParams['sort'], 'date_desc');
    expect(novelParams.containsKey('bmin'), isFalse);
    expect(find.text('收藏数 100 以上'), findsNothing);

    // ...and the illust set survives the round trip either way.
    await tester.tap(_tab('插画 & 漫画'));
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['bmin'], '100');
    expect(find.text('收藏数 100 以上'), findsOneWidget);

    // Back skips the switched tabs and returns to the page before the
    // results.
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SearchResultPage), findsNothing);
    expect(find.byType(SearchInputPage), findsOneWidget);
  });

  testWidgets('a user result route ignores stray filter params', (
    tester,
  ) async {
    final router = await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=user&wmin=800',
    );
    final page = tester.widget<SearchResultPage>(find.byType(SearchResultPage));
    // User searches are filter-free: a shared URL's leftover params never
    // reach the query or the artwork tabs.
    expect(page.query.filtersOrNull, isNull);
    expect(find.byTooltip('筛选'), findsNothing);

    await tester.tap(_tab('小说'));
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['type'], 'novel');
    expect(router.state.uri.queryParameters.containsKey('wmin'), isFalse);
    expect(find.text('宽 800 以上'), findsNothing);
  });

  testWidgets('the filter button counts the active fields; the chip row '
      'only shows while some are active', (tester) async {
    await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=illust',
    );
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最早发布'));
    await tester.tap(find.text('排除 AI'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('筛选（已启用 2 项）'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '最早发布'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '排除 AI'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, '重置'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('筛选'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
  });
}
