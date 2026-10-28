import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/card_world.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/fake_account.dart';

class _RefillScript {
  _RefillScript({
    required this.pages,
    this.localFilterEnabled = true,
    this.filterMinVisible = 4,
    this.filterMaxRefillPages = 2,
    this.novelIds = false,
    this.rejected = const {},
  });

  final List<Object> pages;
  final bool localFilterEnabled;
  final bool novelIds;
  final int filterMinVisible;
  final int filterMaxRefillPages;
  final Set<String> rejected;
  final fetchedCursors = <String?>[];
}

class _RefillFeedController extends PagedFeedController {
  _RefillFeedController(this.script);

  final _RefillScript script;

  @override
  String get feedKey => 'refill-script';

  @override
  bool get localFilterEnabled => script.localFilterEnabled;

  @override
  bool get novelIds => script.novelIds;

  @override
  int get filterMinVisible => script.filterMinVisible;

  @override
  int get filterMaxRefillPages => script.filterMaxRefillPages;

  @override
  String? validateCursor(String? rawCursor) =>
      script.rejected.contains(rawCursor) ? null : rawCursor;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    script.fetchedCursors.add(context.cursor);
    final index = script.fetchedCursors.length - 1;
    if (index >= script.pages.length) {
      throw const ApiHttpError(500, 'unexpected extra refill page');
    }
    final page = script.pages[index];
    if (page is ApiError) throw page;
    return page as FeedPage;
  }
}

final _refillFeedProvider =
    AsyncNotifierProvider.family<
      _RefillFeedController,
      PagedFeedState,
      _RefillScript
    >(_RefillFeedController.new);

IllustEntity _visible(int id) => parseIllust(illustJson(id));

IllustEntity _r18(int id) => parseIllust(illustJson(id, xRestrict: 1));

NovelEntity _novel(int id, {List<Object> tags = const [], int xRestrict = 0}) =>
    NovelEntity.fromJson({
      ...novelJson(id),
      'tags': tags,
      'x_restrict': xRestrict,
    });

/// Pages from a script: '|' separates pages, a negative id is R-18 and a
/// trailing '>' links the last page on. Page n is fetched with cursor 'cn'.
List<FeedPage> _pages(String script) {
  final pages = script.replaceAll('>', '').split('|');
  return [
    for (final (i, page) in pages.indexed)
      _page(
        [
          for (final id in page.trim().split(' ').map(int.parse))
            id < 0 ? _r18(-id) : _visible(id),
        ],
        nextCursor: i + 1 < pages.length || script.endsWith('>')
            ? 'c${i + 2}'
            : null,
      ),
  ];
}

FeedPage _page(List<IllustEntity> illusts, {String? nextCursor}) => FeedPage(
  ids: [for (final illust in illusts) illust.id],
  nextCursor: nextCursor,
  incomingIllusts: {for (final illust in illusts) illust.id: illust},
);

/// A container whose account and settings have loaded.
Future<ProviderContainer> _container({
  required bool blockR18,
  bool hideMuted = false,
  MuteState mutes = const MuteState(),
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final container = ProviderContainer.test(
    overrides: [
      accountStoreProvider.overrideWith(
        () => StubAccountStore(
          accounts: const [Account(id: 'account-a', userId: 1, name: 'tester')],
        ),
      ),
      filterSettings(blockR18: blockR18, hideMuted: hideMuted),
      muteStoreProvider.overrideWith(() => SeededMuteStore(mutes)),
    ],
  );
  await container.read(accountStoreProvider.future);
  await container.read(settingsProvider.future);
  return container;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('refill runs until enough show, the server ends or the cap', () async {
    // Ten wanted, two refills at most.
    for (final (enabled, blockR18, pages, fetched, ids) in [
      (true, true, '1 -2 | 3 -4 | 5 -6 >', 3, [1, 3, 5]),
      (true, true, '1 -2 | 3 -4', 2, [1, 3]),
      (false, true, '1 >', 1, [1]),
      (true, false, '1 2 >', 1, [1, 2]),
    ]) {
      final script = _RefillScript(
        localFilterEnabled: enabled,
        filterMinVisible: 10,
        pages: _pages(pages),
      );
      final container = await _container(blockR18: blockR18);

      final state = await container.read(_refillFeedProvider(script).future);

      expect(script.fetchedCursors, [
        null,
        for (var n = 2; n <= fetched; n++) 'c$n',
      ]);
      expect(state.ids, ids);
      final last = script.pages[fetched - 1] as FeedPage;
      expect(state.exhausted, last.nextCursor == null);
      expect((state.initialPhase, state.initialError), (FeedPhase.idle, null));
    }
  });

  test(
    'a rejected or repeated cursor fails the load like a page\'s own',
    () async {
      // Each page shows one work and holds back one; its next cursor is
      // listed. 'x' is rejected, and the third 'c2' repeats two hops back.
      for (final (next, fetched) in [
        (['x'], [null]),
        (['c2', 'x'], [null, 'c2']),
        (['c2', 'c3', 'c2'], [null, 'c2', 'c3']),
      ]) {
        final script = _RefillScript(
          filterMinVisible: 10,
          filterMaxRefillPages: 3,
          rejected: {'x'},
          pages: [
            for (final (i, cursor) in next.indexed)
              _page([_visible(2 * i + 1), _r18(2 * i + 2)], nextCursor: cursor),
          ],
        );
        final container = await _container(blockR18: true);

        final state = await container.read(_refillFeedProvider(script).future);

        expect(script.fetchedCursors, fetched, reason: '$next');
        expect(state.initialError, isA<ApiParseError>(), reason: '$next');
      }
    },
  );

  test(
    'ApiError during refill keeps visible items and does not surface an error',
    () async {
      final script = _RefillScript(
        filterMinVisible: 10,
        filterMaxRefillPages: 3,
        pages: [..._pages('1 -2 >'), const ApiHttpError(503, 'refill failed')],
      );
      final container = await _container(blockR18: true);

      final state = await container.read(_refillFeedProvider(script).future);

      expect(script.fetchedCursors, [null, 'c2']);
      expect(state.ids, [1]);
      expect(state.initialPhase, FeedPhase.idle);
      expect(state.initialError, isNull);
      expect(state.loadMoreError, isNull);
      expect(state.showInitialError, isFalse);
    },
  );

  test(
    'loadMore first-page ApiError keeps existing ids and reports loadMoreError',
    () async {
      final script = _RefillScript(
        filterMinVisible: 1,
        filterMaxRefillPages: 3,
        pages: [
          ..._pages('1 -2 >'),
          const ApiHttpError(503, 'load more failed'),
        ],
      );
      final container = await _container(blockR18: true);

      final state = await container.read(_refillFeedProvider(script).future);
      expect(state.ids, [1]);
      expect(state.initialPhase, FeedPhase.idle);

      final controller = container.read(_refillFeedProvider(script).notifier);
      await controller.loadMore();
      final after = container.read(_refillFeedProvider(script)).requireValue;
      expect(after.ids, [1]);
      expect(after.loadMorePhase, FeedPhase.error);
      expect(after.loadMoreError, isA<ApiHttpError>());
    },
  );

  test(
    'hide mode drops mute hits, blur keeps them; novels read novels',
    () async {
      // Novel 1 has a muted tag and novel 3 is R-18; an R-18 illust in the
      // store shares novel 2's id and must not hide it (R10).
      for (final (hideMuted, novels, ids) in [
        (true, false, [1]),
        (false, false, [1, 2]),
        (true, true, [2]),
        (false, true, [1, 2]),
      ]) {
        final script = _RefillScript(
          filterMinVisible: 1,
          filterMaxRefillPages: 1,
          novelIds: novels,
          pages: [
            if (novels)
              FeedPage(
                ids: const [1, 2, 3],
                nextCursor: null,
                incomingNovels: {
                  1: _novel(
                    1,
                    tags: [
                      {'name': 'muted'},
                    ],
                  ),
                  2: _novel(2),
                  3: _novel(3, xRestrict: 1),
                },
              )
            else
              _page([_visible(1), _visible(2)]),
          ],
        );
        final container = await _container(
          blockR18: true,
          hideMuted: hideMuted,
          mutes: const MuteState(
            tags: {'muted'},
            works: {2: MutedWork(illustId: 2)},
          ),
        );
        container.read(illustStoreProvider).mergeAll([_r18(2)]);

        final state = await container.read(_refillFeedProvider(script).future);

        expect(
          state.ids,
          ids,
          reason: 'hideMuted: $hideMuted, novels: $novels',
        );
      }
    },
  );
}
