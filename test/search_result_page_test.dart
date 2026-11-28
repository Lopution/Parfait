import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/features/search/docked_search.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/app/widgets/search_field_button.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/search_world.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

Future<GoRouter> _pumpRouter(
  WidgetTester tester, {
  required String initialLocation,
  Locale locale = const Locale('zh', 'CN'),
  Map<String, ApiRoute> routes = const {},
  Size view = const Size(1400, 800),
}) async {
  final router = pixivRouter(initialLocation);
  // Wide surface by default: the whole chip row fits, so every chip is on
  // screen.
  setViewSize(tester, view);
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      container: await searchWorld(SearchApi(), routes: routes),
      locale: locale,
      builder: promptHostBuilder,
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
  return router;
}

/// The illust search: one work a page under a fresh cursor, R-18 until
/// [visible] is set, then a visible last page. [failure] answers instead
/// when set.
class _FilteredSearch {
  var visible = false;
  ApiRoute? failure;
  var _pages = 0;

  FutureOr<http.Response> call(http.Request request) {
    final n = ++_pages;
    if (failure case final fail?) return fail(request);
    return jsonResponse({
      'illusts': [illustJson(n, xRestrict: visible ? 0 : 1)],
      'next_url': visible ? null : nextUrl(request, n),
    });
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
    // User search has no filters, so the artwork filter button is hidden.
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

  testWidgets('an empty result with filters on offers resetting them', (
    tester,
  ) async {
    await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=illust&wmin=1000',
    );
    // The novel results next to it are built too, off screen.
    Finder inEmpty(String text) => find
        .descendant(of: find.byType(FeedEmpty), matching: find.text(text))
        .hitTestable();
    expect(inEmpty('修改搜索'), findsNothing);

    await tester.tap(inEmpty('重置筛选'));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNothing);
    expect(inEmpty('修改搜索'), findsOneWidget);
  });

  testWidgets('loaded pages all filtered: a note offers loading more (B9)', (
    tester,
  ) async {
    final search = _FilteredSearch();
    await seedFilterSettings(blockR18: true);
    await _pumpRouter(
      tester,
      initialLocation: '/search/results?q=cat&type=illust',
      routes: {'/v1/search/illust': search.call},
    );
    expect(find.text('已加载的作品都被屏蔽或筛选掉了'), findsOneWidget);

    // A failed load scrolls to its buttons and retries by itself once the
    // network is back.
    search.failure = offline;
    await tester.tap(find.text('继续加载'));
    await tester.pumpAndSettle();
    final hidden = find.byType(FeedAllHidden);
    expect(
      find.descendant(of: hidden, matching: find.byType(Scrollable)),
      findsOneWidget,
    );
    search.failure = null;
    search.visible = true;
    ProviderScope.containerOf(
        tester.element(hidden),
      ).read(networkRestoreSignalProvider.notifier)
      ..observe(offlineNetworkIdentity)
      ..observe('wifi');
    await tester.pumpAndSettle();
    expect(find.text('已加载的作品都被屏蔽或筛选掉了'), findsNothing);
    expect(find.byType(IllustCard), findsOneWidget);
  });

  testWidgets(
    'editing search query preserves session filters in both wide docked and narrow flows',
    (tester) async {
      for (final (view, nextQuery, surface) in [
        (const Size(1400, 800), 'dog', DockedSearchPanel),
        (const Size(390, 800), 'bird', SearchInputPage),
      ]) {
        final router = await _pumpRouter(
          tester,
          initialLocation:
              '/search/results?q=cat&type=illust&sort=date_asc&bmin=100',
          view: view,
        );
        await tester.tap(find.byType(SearchFieldButton));
        await tester.pumpAndSettle();
        expect(find.byType(surface), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byType(surface),
            matching: find.byType(TextField),
          ),
          nextQuery,
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(router.state.uri.queryParameters['q'], nextQuery);
        expect(router.state.uri.queryParameters['sort'], 'date_asc');
        expect(router.state.uri.queryParameters['bmin'], '100');
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'search refresh failure surfaces a Retry prompt and active tab re-tap triggers refresh',
    (tester) async {
      var calls = 0;
      var fail = false;
      Completer<void>? gate;
      await _pumpRouter(
        tester,
        initialLocation: '/search/results?q=cat&type=illust',
        view: const Size(390, 800),
        routes: {
          '/v1/search/illust': (r) async {
            final n = ++calls;
            final pending = gate;
            if (pending != null) {
              gate = null;
              await pending.future;
            }
            return fail
                ? offline(r)
                : jsonResponse({
                    'illusts': [illustJson(n)],
                    'next_url': null,
                  });
          },
        },
      );
      fail = true;
      await tester.tap(_tab('插画 & 漫画'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('刷新失败'), findsOneWidget);
      fail = false;
      await tester.tap(promptAction('重试'));
      await tester.pumpAndSettle();
      expect(calls, 3);
      await tester.pump(const Duration(seconds: 5));

      // A refresh failing while its tab is hidden must not prompt over the
      // active tab, and replays once the user returns to the failed tab.
      final pendingGate = Completer<void>();
      gate = pendingGate;
      fail = true;
      await tester.tap(_tab('插画 & 漫画'));
      await tester.pump();
      await tester.tap(_tab('用户'));
      await tester.pumpAndSettle();
      pendingGate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新失败'), findsNothing);

      await tester.tap(_tab('插画 & 漫画'));
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新失败'), findsOneWidget);
    },
  );
}
