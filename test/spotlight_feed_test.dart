import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/paging/paged_feed_controller.dart';
import 'package:pixiv_func/core/spotlight/spotlight_feed_controller.dart';
import 'package:pixiv_func/core/spotlight/spotlight_models.dart';
import 'package:pixiv_func/core/spotlight/spotlight_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/spotlight_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('spotlight feed loads page one and commits the article store', () async {
    final (container, fixture) = await makeSpotlightWorld();
    addTearDown(container.dispose);

    final state = await container.read(
      spotlightFeedProvider(SpotlightCategory.all).future,
    );

    expect(state.ids, [101, 102]);
    expect(state.initialPhase, FeedPhase.idle);
    expect(state.exhausted, isFalse);
    expect(fixture.requests.single.queryParameters['category'], 'all');

    final store = container.read(spotlightArticleStoreProvider);
    expect(store[101]?.title, 'spotlight 101');
    expect(store[102]?.articleUrl, 'https://www.pixivision.net/a/102');
  });

  test('categories have independent feeds and cursors', () async {
    final (container, fixture) = await makeSpotlightWorld();
    addTearDown(container.dispose);

    await container.read(spotlightFeedProvider(SpotlightCategory.all).future);
    await container.read(spotlightFeedProvider(SpotlightCategory.manga).future);
    expect(fixture.requests.map((uri) => uri.queryParameters['category']), [
      'all',
      'manga',
    ]);

    await container
        .read(spotlightFeedProvider(SpotlightCategory.manga).notifier)
        .loadMore();
    final manga = container
        .read(spotlightFeedProvider(SpotlightCategory.manga))
        .requireValue;
    final all = container
        .read(spotlightFeedProvider(SpotlightCategory.all))
        .requireValue;
    expect(manga.ids, [101, 102, 103]);
    expect(manga.exhausted, isTrue);
    expect(all.ids, [101, 102]);
    expect(fixture.requests.last.queryParameters['offset'], '10');
  });

  test('a next_url for another category is rejected before page two', () async {
    final (container, fixture) = await makeSpotlightWorld(
      fixture: SpotlightFixture()..mismatchedNextCategory = 'manga',
    );
    addTearDown(container.dispose);

    final state = await container.read(
      spotlightFeedProvider(SpotlightCategory.all).future,
    );

    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(spotlightFeedProvider(SpotlightCategory.all).notifier)
          .nextCursor,
      isNull,
    );
    expect(fixture.requests, hasLength(1));
  });
}
