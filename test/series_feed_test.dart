import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/paging/paged_feed_controller.dart';
import 'package:pixiv_func/core/series/illust_series_context_controller.dart';
import 'package:pixiv_func/core/series/series_feed_controller.dart';
import 'package:pixiv_func/core/series/series_store.dart';
import 'package:pixiv_func/features/series/illust_series_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/series_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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

  testWidgets('series page renders header and works grid', (tester) async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const IllustSeriesPage(seriesId: 55),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // AppBar + header come from the committed series detail.
      expect(find.text('series 55'), findsWidgets);
      expect(find.text('共 12 个作品'), findsOneWidget);
      expect(find.text('author'), findsWidgets);
      expect(find.byType(IllustCard), findsNWidgets(2));
    });
  });
}
