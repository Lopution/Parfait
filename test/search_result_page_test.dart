import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/features/search/search_field_button.dart';

import 'helpers/fake_settings.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/search_world.dart';
import 'helpers/prompt_host.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

Future<GoRouter> _pumpRouter(
  WidgetTester tester, {
  required String initialLocation,
  Locale locale = const Locale('zh', 'CN'),
  FakeSearchRepository? repository,
  List<Override> overrides = const [],
}) async {
  // The input page reads the search history from preferences.
  installMemoryPreferences();
  final router = pixivRouter(initialLocation);
  // Wide surface: the whole chip row fits, so every chip is on screen.
  setViewSize(tester, const Size(1400, 800));
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      overrides: [
        searchRepositoryProvider.overrideWithValue(
          repository ?? FakeSearchRepository(),
        ),
        ...overrides,
      ],
      locale: locale,
      builder: promptHostBuilder,
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
  return router;
}

/// One work a page under a fresh cursor: R-18 until [visible] is set, then
/// a visible last page.
class _FilteredSearch extends FakeSearchRepository {
  var visible = false;
  Object? failure;

  @override
  Future<SearchIllustPage> searchIllust(
    IllustSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(query);
    if (failure case final error?) throw error;
    final n = requests.length;
    return SearchIllustPage(
      illusts: [parseIllust(illustJson(n, xRestrict: visible ? 0 : 1))],
      nextUrl: visible ? null : 'https://app-api.pixiv.net/v1/search?p=$n',
    );
  }
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
    // The user tab keeps the muted filter slot so the search field does not
    // move; tapping it explains that this result kind has no filters.
    expect(find.byTooltip('筛选'), findsOneWidget);
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
    expect(find.byTooltip('筛选'), findsOneWidget);

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

  testWidgets('an empty result with filters on offers resetting them', (
    tester,
  ) async {
    await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=illust&wmin=1000',
    );
    // The novel results next to it are built too, off screen.
    Finder inEmpty(String text) => find.descendant(
      of: find.byType(FeedEmpty).hitTestable(),
      matching: find.text(text),
    );
    expect(inEmpty('修改搜索'), findsNothing);

    await tester.tap(inEmpty('重置筛选'));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNothing);
    expect(inEmpty('修改搜索'), findsOneWidget);
  });

  testWidgets('loaded pages all filtered: a note offers loading more (B9)', (
    tester,
  ) async {
    final repository = _FilteredSearch();
    await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=illust',
      repository: repository,
      overrides: [filterSettings(blockR18: true)],
    );
    expect(find.text('已加载的作品都被屏蔽或筛选掉了'), findsOneWidget);

    // A failed load scrolls to its buttons and retries by itself once the
    // network is back.
    repository.failure = const ApiNetworkError('offline');
    await tester.tap(find.text('继续加载'));
    await tester.pumpAndSettle();
    final hidden = find.byType(FeedAllHidden);
    expect(
      find.descendant(of: hidden, matching: find.byType(Scrollable)),
      findsOneWidget,
    );
    repository.failure = null;
    repository.visible = true;
    ProviderScope.containerOf(
        tester.element(hidden),
      ).read(networkRestoreSignalProvider.notifier)
      ..observe(offlineNetworkIdentity)
      ..observe('wifi');
    await tester.pumpAndSettle();
    expect(find.text('已加载的作品都被屏蔽或筛选掉了'), findsNothing);
    expect(find.byType(IllustCard), findsOneWidget);
  });

  testWidgets('the user filter slot stays in place and explains its scope', (
    tester,
  ) async {
    final router = await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=illust',
    );
    final initialField = tester.getRect(find.byType(SearchFieldButton));

    await tester.tap(_tab('用户'));
    await tester.pumpAndSettle();
    final userField = tester.getRect(find.byType(SearchFieldButton));
    expect(userField.width, closeTo(initialField.width, 0.01));
    expect(find.byTooltip('筛选'), findsOneWidget);

    await tester.tap(find.byTooltip('筛选'));
    await tester.pumpAndSettle();
    expect(find.text('用户搜索没有筛选'), findsOneWidget);
    // Keep the router alive until the prompt has been painted.
    expect(router.state.uri.path, '/search/results');
  });
}
