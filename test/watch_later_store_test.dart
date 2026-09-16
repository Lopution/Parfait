import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/watchlater/watch_later_database.dart';
import 'package:pixiv_func/core/watchlater/watch_later_repository.dart';
import 'package:pixiv_func/core/watchlater/watch_later_store.dart';

IllustEntity _illust(int id, {String title = 'work'}) => IllustEntity(
  id: id,
  title: '$title $id',
  type: IllustType.illust,
  imageUrls: const IllustImageUrls(
    squareMedium: 'https://i.pximg.net/s.jpg',
    medium: 'https://i.pximg.net/m.jpg',
    large: 'https://i.pximg.net/l.jpg',
    original: 'https://i.pximg.net/o.jpg',
  ),
  caption: 'cap $id',
  user: const IllustUser(
    id: 7,
    name: 'author',
    account: 'author',
    profileImageUrl: 'https://i.pximg.net/p.jpg',
  ),
  tags: const [IllustTag(name: 'tag', translatedName: 'tag-en')],
  pageCount: 2,
  width: 1000,
  height: 1400,
  xRestrict: 0,
  aiType: 0,
  isBookmarked: false,
  totalView: 10,
  totalBookmarks: 3,
  metaPages: const [
    IllustImageUrls(
      squareMedium: 'https://i.pximg.net/p0s.jpg',
      medium: 'https://i.pximg.net/p0m.jpg',
      large: 'https://i.pximg.net/p0l.jpg',
      width: 1000,
      height: 1400,
    ),
  ],
  metaSinglePageOriginalUrl: null,
  visible: true,
  createDate: '2026-09-01T00:00:00+09:00',
);

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [
      Account(id: '100', userId: 100, name: 'a'),
      Account(id: '200', userId: 200, name: 'b'),
    ],
    currentId: '100',
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late WatchLaterDatabase database;
  late WatchLaterRepository repository;
  late DateTime now;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('watchlater-test-');
    database = WatchLaterDatabase(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'watchlater.db'),
    );
    now = DateTime.utc(2026, 9, 1);
    repository = WatchLaterRepository(database: database, now: () => now);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('add persists a full entity payload and list restores it', () async {
    await repository.add('100', _illust(1));
    final entries = await repository.list('100');
    expect(entries, hasLength(1));
    final entity = entries.single.entity;
    expect(entity.id, 1);
    expect(entity.title, 'work 1');
    expect(entity.user.name, 'author');
    expect(entity.pageCount, 2);
    expect(entity.metaPages.single.width, 1000);
    expect(entity.tags.single.translatedName, 'tag-en');
    expect(entity.createDate, '2026-09-01T00:00:00+09:00');
  });

  test(
    're-adding the same work is idempotent and moves it to the front',
    () async {
      await repository.add('100', _illust(1));
      await repository.add('100', _illust(2));
      await repository.add('100', _illust(1));
      final entries = await repository.list('100');
      expect(entries.map((e) => e.entity.id), [1, 2]);
    },
  );

  test('entries are isolated per account', () async {
    await repository.add('100', _illust(1));
    await repository.add('200', _illust(2));
    expect(await repository.list('100'), hasLength(1));
    expect((await repository.list('200')).single.entity.id, 2);
    await repository.remove('100', 1);
    expect(await repository.list('100'), isEmpty);
    expect(await repository.list('200'), hasLength(1));
  });

  test('clear removes only the given account rows', () async {
    await repository.add('100', _illust(1));
    await repository.add('200', _illust(2));
    await repository.clear('100');
    expect(await repository.list('100'), isEmpty);
    expect(await repository.list('200'), hasLength(1));
  });

  group('WatchLaterStore', () {
    late ProviderContainer container;

    setUp(() async {
      container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          watchLaterDatabaseProvider.overrideWithValue(database),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
    });

    test('store lists the current account entries', () async {
      await repository.add('100', _illust(1));
      await repository.add('200', _illust(2));
      final entries = await container.read(watchLaterStoreProvider.future);
      expect(entries.map((e) => e.entity.id), [1]);
    });

    test('add/remove through the store invalidate the list', () async {
      final store = container.read(watchLaterStoreProvider.notifier);
      expect(await store.add(_illust(9)), isTrue);
      await container.read(watchLaterStoreProvider.future);
      expect(store.contains(9), isTrue);
      await store.remove(9);
      await container.read(watchLaterStoreProvider.future);
      expect(store.contains(9), isFalse);
    });
  });
}
