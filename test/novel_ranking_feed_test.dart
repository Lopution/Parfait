import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/novel/novel_ranking_feed_controller.dart';
import 'package:parfait/core/novel/novel_repository.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/test_preferences.dart';
import 'helpers/illust_fixtures.dart';

class _RankingFixture {
  final requests = <Uri>[];
  NovelRankingMode? mismatchedNextMode;

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final mode = request.url.queryParameters['mode']!;
    final isFirst = request.url.queryParameters['offset'] == null;
    final start = isFirst ? 1 : 3;
    final nextMode = mismatchedNextMode?.apiValue ?? mode;
    // Pixiv echoes a past ranking's date into next_url.
    final date = request.url.queryParameters['date'];
    return jsonResponse({
      'novels': [
        for (var id = start; id < start + 2; id++)
          novelJson(id, title: 'novel ranking $id'),
      ],
      'next_url': isFirst
          ? 'https://app-api.pixiv.net/v1/novel/ranking'
                '?filter=for_android&mode=$nextMode'
                '${date == null ? '' : '&date=$date'}&offset=30'
          : null,
    });
  });
}

Future<(ProviderContainer, _RankingFixture)> _makeWorld({
  _RankingFixture? fixture,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final activeFixture = fixture ?? _RankingFixture();
  final container = await signedInApiContainer(
    activeFixture.client(),
    overrides: [
      feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
    ],
  );
  return (container, activeFixture);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

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
      fixture: (_RankingFixture()..mismatchedNextMode = NovelRankingMode.week),
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
