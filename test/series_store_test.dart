import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/series/series_models.dart';
import 'package:pixiv_func/core/series/series_store.dart';

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => _stateFor('100');

  void switchCurrentTo(String id) {
    state = AsyncData(_stateFor(id));
  }
}

AccountState _stateFor(String currentId) => AccountState(
  status: AccountStatus.ready,
  accounts: const [
    Account(id: '100', userId: 100, name: 'a'),
    Account(id: '200', userId: 200, name: 'b'),
  ],
  currentId: currentId,
);

IllustSeriesEntity _series(
  int id, {
  String title = 'series',
  String caption = '',
  String? coverUrl,
  int? workCount,
  bool? watchlistAdded,
  bool? isConcluded,
  int? latestContentId,
}) => IllustSeriesEntity(
  id: id,
  title: '$title $id',
  caption: caption,
  userId: 7,
  userName: 'author',
  coverUrl: coverUrl,
  workCount: workCount,
  watchlistAdded: watchlistAdded,
  isConcluded: isConcluded,
  latestContentId: latestContentId,
);

void main() {
  late ProviderContainer container;

  setUp(() async {
    container = ProviderContainer(
      overrides: [accountStoreProvider.overrideWith(_StubAccountStore.new)],
    );
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
  });

  IllustSeriesStore store() =>
      container.read(illustSeriesStoreProvider.notifier);

  test('mergeAll inserts new series and get/getAll resolve ids', () {
    store().mergeAll([_series(1), _series(2, title: 'other')]);
    expect(container.read(illustSeriesStoreProvider).keys, [1, 2]);
    expect(store().get(2)?.title, 'other 2');
    expect(store().getAll([2, 1]).map((e) => e.id), [2, 1]);
  });

  test('a sparse payload keeps previously observed fields', () {
    store().mergeAll([
      _series(
        1,
        caption: 'full caption',
        coverUrl: 'https://i.pximg.net/s1.jpg',
        workCount: 12,
        watchlistAdded: true,
        isConcluded: false,
        latestContentId: 912,
      ),
    ]);

    // A user-series entry carries none of the detail-only fields.
    store().mergeAll([_series(1, title: 'renamed')]);

    final merged = store().get(1)!;
    expect(merged.title, 'renamed 1');
    expect(merged.caption, 'full caption');
    expect(merged.coverUrl, 'https://i.pximg.net/s1.jpg');
    expect(merged.workCount, 12);
    expect(merged.watchlistAdded, isTrue);
    expect(merged.isConcluded, isFalse);
    expect(merged.latestContentId, 912);
  });

  test('a richer payload overwrites fields it carries', () {
    store().mergeAll([_series(1, workCount: 3, isConcluded: false)]);
    store().mergeAll([_series(1, workCount: 4, isConcluded: true)]);
    final merged = store().get(1)!;
    expect(merged.workCount, 4);
    expect(merged.isConcluded, isTrue);
  });

  test('state resets when the current account changes', () {
    store().mergeAll([_series(1)]);
    expect(store().get(1), isNotNull);

    (container.read(accountStoreProvider.notifier) as _StubAccountStore)
        .switchCurrentTo('200');
    container.invalidate(illustSeriesStoreProvider);

    expect(
      container.read(illustSeriesStoreProvider)[1],
      isNull,
      reason: 'account B must not observe account A series entities',
    );
  });
}
