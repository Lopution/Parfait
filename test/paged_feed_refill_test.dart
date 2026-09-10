import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/paging/paged_feed_controller.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/illust_fixtures.dart';

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: 'account-a', userId: 1, name: 'tester')],
    currentId: 'account-a',
  );
}

class _SettingsController extends SettingsController {
  _SettingsController({this.blockR18 = false});

  final bool blockR18;

  @override
  Future<AppSettings> build() async =>
      AppSettings.defaults().copyWith(enableLocalBlockR18: blockR18);
}

class _RefillScript {
  _RefillScript({
    required this.pages,
    this.localFilterEnabled = true,
    this.filterMinVisible = 4,
    this.filterMaxRefillPages = 2,
  });

  final List<Object> pages;
  final bool localFilterEnabled;
  final int filterMinVisible;
  final int filterMaxRefillPages;
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
  int get filterMinVisible => script.filterMinVisible;

  @override
  int get filterMaxRefillPages => script.filterMaxRefillPages;

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

FeedPage _page(List<IllustEntity> illusts, {String? nextCursor}) {
  return FeedPage(
    ids: [for (final illust in illusts) illust.id],
    nextCursor: nextCursor,
    incomingIllusts: {for (final illust in illusts) illust.id: illust},
  );
}

ProviderContainer _container({required bool blockR18}) {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  return ProviderContainer(
    overrides: [
      accountStoreProvider.overrideWith(_StubAccountStore.new),
      settingsProvider.overrideWith(
        () => _SettingsController(blockR18: blockR18),
      ),
    ],
  );
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test(
    'refill stops after filterMaxRefillPages extra pages as a normal load',
    () async {
      final script = _RefillScript(
        filterMinVisible: 10,
        filterMaxRefillPages: 2,
        pages: [
          _page([_visible(1), _r18(2)], nextCursor: 'c2'),
          _page([_visible(3), _r18(4)], nextCursor: 'c3'),
          _page([_visible(5), _r18(6)], nextCursor: 'c4'),
          _page([_visible(7), _r18(8)], nextCursor: 'c5'),
        ],
      );
      final container = _container(blockR18: true);
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      await container.read(settingsProvider.future);

      final state = await container.read(_refillFeedProvider(script).future);

      expect(script.fetchedCursors, [null, 'c2', 'c3']);
      expect(state.ids, [1, 3, 5]);
      expect(state.initialPhase, FeedPhase.idle);
      expect(state.initialError, isNull);
      expect(state.loadMoreError, isNull);
      expect(state.showInitialError, isFalse);
    },
  );

  test('refill stops when the server returns a null cursor', () async {
    final script = _RefillScript(
      filterMinVisible: 10,
      filterMaxRefillPages: 3,
      pages: [
        _page([_visible(1), _r18(2)], nextCursor: 'c2'),
        _page([_visible(3), _r18(4)]),
        _page([_visible(5), _r18(6)], nextCursor: 'unused'),
      ],
    );
    final container = _container(blockR18: true);
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    await container.read(settingsProvider.future);

    final state = await container.read(_refillFeedProvider(script).future);

    expect(script.fetchedCursors, [null, 'c2']);
    expect(state.ids, [1, 3]);
    expect(state.exhausted, isTrue);
    expect(state.initialPhase, FeedPhase.idle);
    expect(state.initialError, isNull);
  });

  test(
    'ApiError during refill keeps visible items and does not surface an error',
    () async {
      final script = _RefillScript(
        filterMinVisible: 10,
        filterMaxRefillPages: 3,
        pages: [
          _page([_visible(1), _r18(2)], nextCursor: 'c2'),
          const ApiHttpError(503, 'refill failed'),
        ],
      );
      final container = _container(blockR18: true);
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      await container.read(settingsProvider.future);

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
          _page([_visible(1), _r18(2)], nextCursor: 'c2'),
          const ApiHttpError(503, 'load more failed'),
        ],
      );
      final container = _container(blockR18: true);
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      await container.read(settingsProvider.future);

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

  test('no refill happens when local filtering is disabled', () async {
    final script = _RefillScript(
      localFilterEnabled: false,
      filterMinVisible: 10,
      filterMaxRefillPages: 3,
      pages: [
        _page([_visible(1)], nextCursor: 'c2'),
        _page([_visible(2)]),
      ],
    );
    final container = _container(blockR18: true);
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    await container.read(settingsProvider.future);

    final state = await container.read(_refillFeedProvider(script).future);

    expect(script.fetchedCursors, [null]);
    expect(state.ids, [1]);
    expect(state.initialPhase, FeedPhase.idle);
  });

  test('no refill happens when a filter is on but nothing is hidden', () async {
    final script = _RefillScript(
      filterMinVisible: 10,
      filterMaxRefillPages: 3,
      pages: [
        _page([_visible(1), _visible(2)], nextCursor: 'c2'),
        _page([_visible(3)]),
      ],
    );
    final container = _container(blockR18: false);
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    await container.read(settingsProvider.future);

    final state = await container.read(_refillFeedProvider(script).future);

    expect(script.fetchedCursors, [null]);
    expect(state.ids, [1, 2]);
    expect(state.initialPhase, FeedPhase.idle);
  });
}
