import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_tag_providers.dart';
import 'package:parfait/core/bookmark/bookmark_tags_controller.dart';
import 'package:parfait/core/illust/illust_detail_controller.dart';
import 'package:parfait/core/series/illust_series_context_controller.dart';
import 'package:parfait/core/series/series_store.dart';
import 'package:parfait/core/user/user_detail_controller.dart';
import 'package:parfait/core/user/user_store.dart';
import 'package:parfait/core/watchlist/watchlist_feed_controller.dart';
import 'package:parfait/core/watchlist/watchlist_models.dart';
import 'package:parfait/core/watchlist/watchlist_store.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

// Account A ('100', access-1) answers 9 / user 42 / illust 7 / series 3 /
// tag 'a' / 7 bookmarked; B ('200') answers 10 / 404 / 404 / 404 / tag 'b' /
// 7 not bookmarked. A's responses
// wait on [_gate]; B's come at once.
late Completer<void> _gate;

const _profileCounts = [
  'follow_users',
  'mypixiv_users',
  'illusts',
  'manga',
  'novels',
  'illust_bookmarks_public',
  'illust_series',
  'novel_series',
];

http.Response _respond(Uri url, bool b) => switch (url.path) {
  '/v1/watchlist/manga' => jsonResponse({
    'series': [
      {
        'id': b ? 10 : 9,
        'title': 's',
        'user': {'id': 5},
      },
    ],
    'next_url': _next(url, b),
  }),
  '/v1/user/bookmark-tags/illust' => jsonResponse({
    'bookmark_tags': [
      {'name': b ? 'b' : 'a', 'count': 1},
    ],
    'next_url': _next(url, b),
  }),
  '/v2/illust/bookmark/detail' => jsonResponse({
    'bookmark_detail': {
      'is_bookmarked': !b,
      'restrict': 'public',
      'tags': <Object>[],
    },
  }),
  _ when b => jsonResponse({}, 404),
  '/v1/user/detail' => jsonResponse({
    'user': {'id': 42, 'name': 'a', 'profile_image_urls': <String, String>{}},
    'profile': {for (final count in _profileCounts) 'total_$count': 0},
  }),
  '/v1/illust/detail' => jsonResponse({'illust': illustJson(7)}),
  _ => jsonResponse({
    'illust_series_detail': {
      'id': 3,
      'title': 's',
      'user': {'id': 5},
    },
    'illust_series_context': {'series_id': 3},
  }),
};

/// A's first pages have a second page; B's and second pages do not.
String? _next(Uri url, bool b) => b || url.queryParameters.containsKey('offset')
    ? null
    : url
          .replace(queryParameters: {...url.queryParameters, 'offset': '30'})
          .toString();

Future<ProviderContainer> _world() async {
  installMemoryPreferences();
  _gate = Completer<void>();
  final container = await signedInApiContainer(
    MockClient((request) async {
      final b = request.headers['authorization']!.contains('access-200');
      if (!b) await _gate.future;
      return _respond(request.url, b);
    }),
    others: const [Account(id: '200', userId: 200, name: 'b')],
    overrides: [actionStoreProvider.overrideWithValue(InMemoryActionStore())],
  );
  addTearDown(container.dispose);
  return container;
}

/// Switches to B while A's requests are held and reads [reads] for B, as
/// the UI does, then lets A's responses land: before the dependents
/// rebuild (their old refs are still mounted then) or, with [rebuilt],
/// after B's own loads.
Future<void> _switchThenRelease(
  ProviderContainer container,
  List<ProviderListenable<Object?>> reads, {
  bool rebuilt = false,
}) async {
  await container.read(accountStoreProvider.notifier).switchAccount('200');
  reads.forEach(container.read);
  if (rebuilt) await pumpEventQueue();
  _gate.complete();
  await pumpEventQueue();
}

void main() {
  const tags = (BookmarkEntityType.illust, BookmarkRestrict.public);

  test(
    'A\'s first loads landing after the switch stay out of B\'s stores',
    () async {
      final container = await _world();
      final dependents = [
        watchlistFeedProvider(WatchlistType.manga),
        userDetailControllerProvider(42),
        illustSeriesContextProvider(7),
      ];
      for (final provider in dependents) {
        container.listen(provider, (_, _) {});
      }
      // The bookmark sheet's prefill.
      final detail = bookmarkDetailProvider(
        const BookmarkKey(BookmarkEntityType.illust, 7),
      );
      final seen = <bool?>[];
      container.listen(detail, (_, next) => seen.add(next.value?.isBookmarked));
      await _switchThenRelease(container, [
        watchlistStoreProvider,
        userStoreProvider,
        illustSeriesStoreProvider,
      ]);

      final watched = container.read(watchlistStoreProvider).keys;
      expect(watched.map((key) => key.seriesId), [10]);
      expect(container.read(userStoreProvider), isEmpty);
      expect(container.read(illustSeriesStoreProvider), isEmpty);
      expect(seen, isNot(contains(true)));
      expect((await container.read(detail.future)).isBookmarked, isFalse);
    },
  );

  test('A\'s reloads landing around B\'s rebuild leave B\'s state', () async {
    // Before the rebuild, a listener would see A's page for one flush.
    for (final rebuilt in [false, true]) {
      final container = await _world();
      final user = userDetailControllerProvider(42);
      final illust = illustDetailControllerProvider(7);
      final tagList = userBookmarkTagsProvider(tags);
      final watchlist = watchlistFeedProvider(WatchlistType.manga);
      final seen = <Object?>[];
      for (final provider in [user, illust]) {
        container.listen(provider, (_, next) => seen.add(next.value));
      }
      container.listen(tagList, (_, next) => seen.add(next.value?.tags));
      container.listen(watchlist, (_, next) => seen.add(next.value?.entries));
      _gate.complete();
      await pumpEventQueue();
      _gate = Completer<void>();
      unawaited(container.read(user.notifier).reload());
      unawaited(container.read(illust.notifier).reload());
      unawaited(container.read(tagList.notifier).loadMore());
      unawaited(container.read(watchlist.notifier).loadMore());
      seen.clear();
      await _switchThenRelease(container, [
        if (rebuilt) ...[user, illust, tagList, watchlist],
      ], rebuilt: rebuilt);

      final reason = 'rebuilt: $rebuilt';
      expect(container.read(user).value, isA<UserDetailNotFound>());
      expect(container.read(illust).value, isA<IllustDetailNotFound>());
      final names = container.read(tagList).value!.tags.map((tag) => tag.name);
      expect(names, ['b'], reason: reason);
      final entries = container.read(watchlist).value!.entries;
      expect(entries.map((entry) => entry.id), [10], reason: reason);
      final watched = container.read(watchlistStoreProvider).keys;
      expect(watched.map((key) => key.seriesId), [10], reason: reason);
      expect(
        seen.whereType<List<Object?>>().where((list) => list.length > 1),
        isEmpty,
        reason: 'A\'s second page reached a listener ($reason)',
      );
      expect(
        seen,
        isNot(
          anyElement(anyOf(isA<UserDetailReady>(), isA<IllustDetailReady>())),
        ),
        reason: 'A\'s detail reached a listener ($reason)',
      );
    }
  });
}
