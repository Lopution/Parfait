import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/network/api_error.dart';

import 'package:parfait/core/illust/recommended_feed_controller.dart';
import 'package:parfait/core/illust/recommended_repository.dart'
    show RecommendedContentType;

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';

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
}
