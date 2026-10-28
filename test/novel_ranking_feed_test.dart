import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/novel/novel_ranking_feed_controller.dart';
import 'package:parfait/core/novel/novel_repository.dart';
import 'package:parfait/core/novel/novel_store.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/illust_fixtures.dart';

Future<(ProviderContainer, NovelRankingFixture)> _makeWorld({
  NovelRankingFixture? fixture,
}) async {
  final activeFixture = fixture ?? NovelRankingFixture();
  final container = await signedInApiContainer(
    activeFixture.client(),
    overrides: [
      feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
    ],
  );
  return (container, activeFixture);
}

void main() {
  test('each mode has independent first page and load-more state', () async {
    final (container, fixture) = await _makeWorld();

    final day = await container.read(
      novelRankingFeedProvider((mode: NovelRankingMode.day, date: null)).future,
    );
    final week = await container.read(
      novelRankingFeedProvider((
        mode: NovelRankingMode.week,
        date: null,
      )).future,
    );
    expect(day.ids, [1, 2]);
    expect(week.ids, [1, 2]);
    expect(fixture.requests.map((uri) => uri.path), [
      '/v1/novel/ranking',
      '/v1/novel/ranking',
    ]);
    expect(fixture.requests.map((uri) => uri.queryParameters['mode']), [
      'day',
      'week',
    ]);

    await container
        .read(
          novelRankingFeedProvider((
            mode: NovelRankingMode.day,
            date: null,
          )).notifier,
        )
        .loadMore();
    final dayAfter = container
        .read(
          novelRankingFeedProvider((mode: NovelRankingMode.day, date: null)),
        )
        .requireValue;
    final weekAfter = container
        .read(
          novelRankingFeedProvider((mode: NovelRankingMode.week, date: null)),
        )
        .requireValue;
    expect(dayAfter.ids, [1, 2, 3, 4]);
    expect(weekAfter.ids, [1, 2]);
    expect(weekAfter.exhausted, isFalse);
  });

  test('entities land in the novel store under ranking ids', () async {
    final (container, _) = await _makeWorld();

    await container.read(
      novelRankingFeedProvider((mode: NovelRankingMode.day, date: null)).future,
    );
    final store = container.read(novelStoreProvider);
    expect(store[1]?.title, 'novel ranking 1');
    expect(store[2]?.id, 2);
  });

  test('mismatched next mode is an observable parse error', () async {
    final (container, _) = await _makeWorld(
      fixture: (NovelRankingFixture()
        ..mismatchedNextMode = NovelRankingMode.week),
    );

    final state = await container.read(
      novelRankingFeedProvider((mode: NovelRankingMode.day, date: null)).future,
    );
    expect(state.showInitialError, isTrue);
    expect(state.initialError, isNotNull);
    expect(
      container
          .read(
            novelRankingFeedProvider((
              mode: NovelRankingMode.day,
              date: null,
            )).notifier,
          )
          .nextCursor,
      isNull,
    );
  });

  group('ranking date', () {
    final pastDay = DateTime(2025, 10, 1);

    test('a past day is requested and paged with its date', () async {
      final (container, fixture) = await _makeWorld();
      final provider = novelRankingFeedProvider((
        mode: NovelRankingMode.day,
        date: pastDay,
      ));

      await container.read(provider.future);
      await container.read(provider.notifier).loadMore();

      expect(fixture.requests, hasLength(2));
      for (final request in fixture.requests) {
        expect(request.queryParameters['date'], '2025-10-01');
      }
    });

    test('a cursor from another day is rejected', () async {
      final (container, _) = await _makeWorld();
      final repository = container.read(novelRepositoryProvider);
      const base = 'https://app-api.pixiv.net/v1/novel/ranking?mode=day';

      expect(
        repository.validateRankingCursor(
          NovelRankingMode.day,
          cursor: '$base&date=2025-10-01',
          date: pastDay,
        ),
        isTrue,
      );
      expect(
        repository.validateRankingCursor(
          NovelRankingMode.day,
          cursor: '$base&date=2025-09-30',
          date: pastDay,
        ),
        isFalse,
      );
      expect(
        repository.validateRankingCursor(
          NovelRankingMode.day,
          cursor: base,
          date: pastDay,
        ),
        isFalse,
      );
      expect(
        repository.validateRankingCursor(
          NovelRankingMode.day,
          cursor: '$base&date=2025-10-01',
        ),
        isFalse,
      );
    });
  });
}
