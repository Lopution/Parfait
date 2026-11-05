import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';

import 'package:parfait/core/illust/recommended_feed_controller.dart';
import 'package:parfait/core/illust/recommended_repository.dart'
    show RecommendedContentType;

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/waits.dart';

/// Local transport serving deterministic recommended pages.
/// Page flow: offset-less page 1 (ids 1..10, next=page2) →
/// page2 (ids 8..15 to force a cross-page dupe, next=null).
class _ApiFixture {
  _ApiFixture({this.nextUrlOverride});

  /// When non-null, page responses always carry this (possibly malicious)
  /// next_url to test allowlist rejection.
  final String? nextUrlOverride;

  var pageRequests = 0;

  http.Client build() {
    return MockClient((request) async {
      if (request.url.host != 'app-api.pixiv.net') {
        return http.Response('unknown host should not be requested', 500);
      }
      pageRequests += 1;
      final first = request.url.queryParameters['offset'] == null;
      final start = first ? 1 : 8;
      final ids = [for (var i = start; i < start + 10; i++) i];
      final nextUrl =
          nextUrlOverride ??
          (first
              ? 'https://app-api.pixiv.net/v1/illust/recommended?offset=30'
              : null);
      return jsonResponse({
        'illusts': [
          for (final id in ids) illustJson(id, bookmarked: id == 8 && !first),
        ],
        'next_url': nextUrl,
      });
    });
  }
}

final _feed = recommendedFeedProvider((type: RecommendedContentType.illust));

Future<(ProviderContainer, _ApiFixture)> makeWorld({
  String? nextUrlOverride,
  bool failApi = false,
}) async {
  final fixture = _ApiFixture(nextUrlOverride: nextUrlOverride);
  final container = await signedInApiContainer(
    failApi
        ? MockClient((request) async {
            throw http.ClientException('network unreachable');
          })
        : fixture.build(),
  );
  return (container, fixture);
}

void main() {
  test('initial load fetches real-shaped pages and merges the store', () async {
    final (container, _) = await makeWorld();

    final controller = container.read(_feed.notifier);
    final state = await container.read(_feed.future);

    expect(state.showInitialError, isFalse);
    expect(state.ids, hasLength(10));
    final store = container.read(illustStoreProvider);
    expect(store.get(1)!.title, 'illust 1');
    expect(controller.nextCursor, isNotNull);
  });

  test('load-more deduplicates across pages and reaches exhausted', () async {
    final (container, fixture) = await makeWorld();

    final controller = container.read(_feed.notifier);
    await container.read(_feed.future);
    await controller.loadMore();

    final state = container.read(_feed).requireValue;
    // Page 1: 1..10; page 2: 8..17 → three duplicates (8,9,10) collapse.
    expect(state.ids, hasLength(17));
    expect(state.ids.toSet().length, 17);
    expect(state.exhausted, isTrue);
    expect(fixture.pageRequests, 2);
  });

  test('malicious next_url is rejected and surfaces an error', () async {
    final (container, _) = await makeWorld(
      nextUrlOverride:
          'https://evil.example.com/v1/illust/recommended?offset=1',
    );

    final controller = container.read(_feed.notifier);
    // Page 1 validates its cursor via the allowlist: a rejected cursor
    // surfaces an explicit error instead of navigating to a foreign host.
    final state = await container.read(_feed.future);

    expect(
      state.showInitialError,
      isTrue,
      reason: 'a rejected malicious cursor must be an observable error',
    );
    expect(state.initialError, isA<ApiParseError>());
    expect(controller.nextCursor, isNull);
    expect(state.ids, isEmpty);
  });

  // Live regression: /v1/novel/recommended answers a next_url whose filter
  // flips to for_ios (and drops include_* hints). The cursor validator pins
  // feed identity only, so paging must continue instead of dying with a
  // NextPageParseError.
  test(
    'novel recommended follows a next_url with a rewritten filter',
    () async {
      var pageRequests = 0;
      final transport = MockClient((request) async {
        pageRequests += 1;
        final first = request.url.queryParameters['offset'] == null;
        return jsonResponse({
          'novels': [
            for (var id = first ? 1 : 3; id < (first ? 3 : 5); id++)
              novelJson(id, title: 'recommended novel $id'),
          ],
          'next_url': first
              ? 'https://app-api.pixiv.net/v1/novel/recommended'
                    '?filter=for_ios&offset=30'
              : null,
        });
      });
      final container = await signedInApiContainer(transport);

      const key = (type: RecommendedContentType.novel);
      final first = await container.read(recommendedFeedProvider(key).future);
      expect(first.ids, [1, 2]);
      expect(first.showInitialError, isFalse);

      await container.read(recommendedFeedProvider(key).notifier).loadMore();
      final after = container.read(recommendedFeedProvider(key)).requireValue;
      expect(
        after.ids,
        [1, 2, 3, 4],
        reason:
            'a next_url whose client params Pixiv rewrote must still page; '
            'only feed-identity params are validated',
      );
      expect(pageRequests, 2);
    },
  );

  test('initial network failure surfaces a retryable error state', () async {
    final (container, _) = await makeWorld(failApi: true);

    final state = await container.read(_feed.future);
    expect(state.showInitialError, isTrue);
    expect(state.initialError, isA<ApiError>());

    final controller = container.read(_feed.notifier);
    await controller.retryInitial();
    final retried = container.read(_feed).requireValue;
    expect(retried.showInitialError, isTrue);
  });

  testWidgets('IllustCard includes its live page scope in the Hero tag', (
    tester,
  ) async {
    final (container, _) = await makeWorld();
    final entity = parseIllust(illustJson(8));
    await tester.pumpWidget(
      localizedApp(
        container: container,
        home: SingleChildScrollView(
          child: Column(
            children: [
              IllustCard(entity: entity, heroScope: 'ranking:day'),
              IllustCard(entity: entity, heroScope: 'search:blue-archive'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final tags = tester
        .widgetList<Hero>(find.byType(Hero))
        .map((hero) => hero.tag);
    expect(tags, contains('IllustHero:ranking:day:8'));
    expect(tags, contains('IllustHero:search:blue-archive:8'));
  });

  for (final quality in PreviewQuality.values) {
    testWidgets("a tall card keeps its Hero only on pixiv's own top square, "
        'which alone fetches the whole work in the background (${quality.name})', (
      tester,
    ) async {
      // Every body held open: each request stays in flight.
      final client = HeldBodyClient();
      final worker = inProcessImageWorker(() => client);
      final container = await signedInApiContainer(
        MockClient((request) async => http.Response('{}', 200)),
        overrides: [
          imageWorkerProvider.overrideWithValue(worker),
          previewQualityProvider.overrideWithValue(quality),
        ],
      );
      IllustEntity tall(int id, String squareMedium, {String type = 'illust'}) {
        final json = illustJson(id, width: 1000, height: 8000, type: type);
        (json['image_urls'] as Map<String, dynamic>)['square_medium'] =
            squareMedium;
        return parseIllust(json);
      }

      const dir = 'img/2024/01/02/03/04/05';
      const own =
          'https://i.pximg.net/c/360x360_70/img-master/$dir/1_p0_square1200.jpg';
      const custom =
          'https://i.pximg.net/c/360x360_70/custom-thumb/$dir/2_p0_custom1200.jpg';
      final entities = [
        tall(1, own),
        tall(2, custom),
        // An ugoira's cover lays out no top square.
        tall(3, own, type: 'ugoira'),
        parseIllust(illustJson(4)),
      ];
      Widget feed() => localizedApp(
        container: container,
        home: SingleChildScrollView(
          child: Column(
            children: [
              for (final entity in entities)
                IllustCard(entity: entity, heroScope: 'feed'),
            ],
          ),
        ),
      );
      await tester.pumpWidget(feed());
      await tester.pump();
      final tags = tester
          .widgetList<Hero>(find.byType(Hero))
          .map((hero) => '${hero.tag}')
          .where((tag) => tag.startsWith('IllustHero:'));
      expect(tags, ['IllustHero:feed:1', 'IllustHero:feed:4']);
      final copy = entities.first.previewUrl(quality);
      // The cards' own images (the ugoira's cover is card 1's square
      // here), and the copy.
      await pumpIoUntil(tester, () => client.urls.length == 4);
      expect(client.urls.where((url) => url == copy), hasLength(1));
      // The copy is no on-screen load: it went on the background lane.
      expect(worker.foregroundLoads.value, 3);
      // A held request is a pending cache entry, made when it is asked
      // for: a second request for a file needs a second entry.
      final cache = PaintingBinding.instance.imageCache;
      final pending = cache.pendingImageCount;
      // A rebuild asks for nothing again.
      await tester.pumpWidget(feed());
      expect(cache.pendingImageCount, pending);

      // A press decodes the copy and the page image at the page's width,
      // as the card and the page do, and warms the author's avatar.
      final press = await tester.startGesture(
        tester.getCenter(find.byType(IllustCard).first),
      );
      await tester.pump(kPressTimeout);
      await press.cancel();
      final large = entities.first.imageUrls.large;
      expect(cache.pendingImageCount, pending + (large == copy ? 1 : 2));
      await pumpIoUntil(tester, () => client.urls.contains(large));
      expect(client.urls.where((url) => url == copy), hasLength(1));
      expect(client.urls.where((url) => url == large), hasLength(1));
      await unmountPastReleaseGrace(tester);
    });
  }
}
