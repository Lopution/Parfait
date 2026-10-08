import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/core/series/illust_series_context_controller.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/series/series_feed_controller.dart';
import 'package:parfait/core/series/series_recent_open_store.dart';
import 'package:parfait/core/series/series_store.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/series_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    // Navigating into the detail page brings VisibilityDetector-based page
    // tracking; a zero interval keeps timers out of test teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  test(
    'illust series feed loads page one and commits entities plus detail',
    () async {
      final (container, fixture) = await makeSeriesWorld();
      addTearDown(container.dispose);

      final state = await container.read(illustSeriesFeedProvider(55).future);

      expect(state.ids, [912, 911]);
      expect(state.initialPhase, FeedPhase.idle);
      expect(state.exhausted, isFalse);
      expect(fixture.requests.single.path, '/v1/illust/series');
      expect(fixture.requests.single.queryParameters['illust_series_id'], '55');
      expect(fixture.requests.single.queryParameters['filter'], 'for_android');

      final illustStore = container.read(illustStoreProvider);
      expect(illustStore.get(912)?.title, 'illust 912');
      final seriesStore = container.read(illustSeriesStoreProvider);
      expect(seriesStore[55]?.workCount, 12);
      expect(seriesStore[55]?.latestContentId, 912);
    },
  );

  test('illust series feed paginates with the last_order cursor', () async {
    final (container, fixture) = await makeSeriesWorld();
    addTearDown(container.dispose);

    await container.read(illustSeriesFeedProvider(55).future);
    await container.read(illustSeriesFeedProvider(55).notifier).loadMore();
    final after = container.read(illustSeriesFeedProvider(55)).requireValue;

    expect(after.ids, [912, 911, 910]);
    expect(after.exhausted, isTrue);
    expect(fixture.requests, hasLength(2));
    expect(fixture.requests.last.queryParameters['last_order'], '10');
    expect(fixture.requests.last.queryParameters['illust_series_id'], '55');
  });

  test(
    'a next_url for another series id is rejected before page two',
    () async {
      final (container, fixture) = await makeSeriesWorld(
        fixture: SeriesFixture()..mismatchedSeriesId = 56,
      );
      addTearDown(container.dispose);

      final state = await container.read(illustSeriesFeedProvider(55).future);

      expect(state.showInitialError, isTrue);
      expect(state.initialError, isNotNull);
      expect(
        container.read(illustSeriesFeedProvider(55).notifier).nextCursor,
        isNull,
      );
      expect(fixture.requests, hasLength(1));
    },
  );

  test('user series feed stores series ids and merges the store', () async {
    final (container, fixture) = await makeSeriesWorld();
    addTearDown(container.dispose);

    final state = await container.read(userSeriesFeedProvider(7).future);
    expect(state.ids, [55, 56]);
    expect(fixture.requests.single.path, '/v1/user/illust-series');
    expect(fixture.requests.single.queryParameters['user_id'], '7');

    await container.read(userSeriesFeedProvider(7).notifier).loadMore();
    final after = container.read(userSeriesFeedProvider(7)).requireValue;
    expect(after.ids, [55, 56, 57]);
    expect(after.exhausted, isTrue);
    expect(fixture.requests.last.queryParameters['offset'], '2');

    final store = container.read(illustSeriesStoreProvider);
    expect(store[55]?.title, 'series 55');
    expect(store[56]?.workCount, 3);
    expect(store[57]?.workCount, 5);
  });

  test('illust series context merges detail and neighbour illusts', () async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);

    final context = await container.read(
      illustSeriesContextProvider(910).future,
    );

    expect(context?.seriesId, 55);
    expect(context?.contentOrder, 3);
    expect(context?.prevIllustId, 909);
    expect(context?.nextIllustId, 911);
    expect(container.read(illustSeriesStoreProvider)[55]?.id, 55);
    final illustStore = container.read(illustStoreProvider);
    expect(illustStore.get(909)?.title, 'illust 909');
    expect(illustStore.get(911)?.title, 'illust 911');
  });

  test('non-series work resolves to a null context', () async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);

    final context = await container.read(
      illustSeriesContextProvider(42).future,
    );

    expect(context, isNull);
    expect(container.read(illustSeriesStoreProvider), isEmpty);
  });

  Future<void> pumpSeriesPage(
    WidgetTester tester,
    ProviderContainer container, {
    int seriesId = 55,
  }) async {
    final router = createPixivRouter(
      initialLocation: '/recommended/series/$seriesId',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with a reading record: continue first, start over second', (
    tester,
  ) async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);
    // The session memory recorded part 2 (illust 911); the detail payload
    // independently carries first=901 and latest=912.
    container
        .read(seriesRecentOpenStoreProvider.notifier)
        .record(accountId: '100', seriesId: 55, illustId: 911, contentOrder: 2);

    await mockNetworkImagesFor(() async {
      await pumpSeriesPage(tester, container);
    });

    final resume = find.widgetWithText(FilledButton, '继续第 2 话');
    final startOver = find.widgetWithText(TextButton, '从第 1 话开始');
    expect(resume, findsOneWidget);
    expect(startOver, findsOneWidget);
    expect(find.text('开始阅读'), findsNothing);

    // 继续第 n 话 opens the session-recorded work (911), not the markSeen
    // cursor's latest (912) — distinct state sources (W4 gate).
    await tester.tap(resume);
    await tester.pumpAndSettle();
    final resumed = tester.widget<IllustDetailPage>(
      find.byType(IllustDetailPage),
    );
    expect(resumed.illustId, 911);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 从第 1 话开始 opens the first work (firstContentId=901).
    await tester.tap(startOver);
    await tester.pumpAndSettle();
    final first = tester.widget<IllustDetailPage>(
      find.byType(IllustDetailPage),
    );
    expect(first.illustId, 901);

    // markSeen is untouched and still tracked by its own store.
    final cursor = container.read(watchlistReadCursorProvider);
    expect(
      await cursor.read('100', WatchlistKey(WatchlistType.manga, 55)),
      912,
    );
  });
}
