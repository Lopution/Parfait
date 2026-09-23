import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/series/series_recent_open_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'helpers/test_preferences.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    installMemoryPreferences();
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  SeriesRecentOpenStore store() =>
      container.read(seriesRecentOpenStoreProvider.notifier);

  test('record then read resolves the same entry', () {
    store().record(
      accountId: '100',
      seriesId: 55,
      illustId: 912,
      contentOrder: 12,
    );

    final entry = store().read(accountId: '100', seriesId: 55);
    expect(entry?.illustId, 912);
    expect(entry?.contentOrder, 12);
    expect(store().read(accountId: '100', seriesId: 56), isNull);
  });

  test('a later record overwrites; an identical record is a no-op', () {
    store().record(
      accountId: '100',
      seriesId: 55,
      illustId: 912,
      contentOrder: 12,
    );
    final firstState = container.read(seriesRecentOpenStoreProvider);

    // Same write → state object unchanged (rebuilds must not churn).
    store().record(
      accountId: '100',
      seriesId: 55,
      illustId: 912,
      contentOrder: 12,
    );
    expect(
      identical(firstState, container.read(seriesRecentOpenStoreProvider)),
      isTrue,
    );

    store().record(
      accountId: '100',
      seriesId: 55,
      illustId: 913,
      contentOrder: 13,
    );
    expect(store().read(accountId: '100', seriesId: 55)?.illustId, 913);
  });

  test('keys are account-scoped — parallel accounts stay isolated', () {
    store().record(
      accountId: '100',
      seriesId: 55,
      illustId: 912,
      contentOrder: 12,
    );
    store().record(
      accountId: '200',
      seriesId: 55,
      illustId: 901,
      contentOrder: 1,
    );

    expect(store().read(accountId: '100', seriesId: 55)?.illustId, 912);
    expect(store().read(accountId: '200', seriesId: 55)?.illustId, 901);
    expect(
      SeriesRecentOpenStore.keyFor('100', 55),
      isNot(SeriesRecentOpenStore.keyFor('200', 55)),
    );
  });

  test('the store never touches SharedPreferences (session-only)', () async {
    store().record(
      accountId: '100',
      seriesId: 55,
      illustId: 912,
      contentOrder: 12,
    );

    final keys = await SharedPreferencesAsyncPlatform.instance!.getKeys(
      const GetPreferencesParameters(filter: PreferencesFilters()),
      const SharedPreferencesOptions(),
    );
    expect(keys, isEmpty);
  });
}
