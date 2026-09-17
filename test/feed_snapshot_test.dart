import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_func/core/paging/feed_database.dart';
import 'package:pixiv_func/core/paging/feed_snapshot_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('FeedSnapshotStore', () {
    late Directory directory;
    late FeedDatabase database;
    late FeedSnapshotStore store;
    late DateTime now;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('pixiv-feeds-test-');
      database = FeedDatabase(
        factory: databaseFactoryFfi,
        databasePath: path.join(directory.path, 'feeds.db'),
      );
      now = DateTime.utc(2026, 9, 18, 12);
      store = FeedSnapshotStore(database: database, now: () => now);
    });

    tearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });

    Map<String, Object?> entitiesOf(List<int> ids) => {
      'illust': {
        for (final id in ids) '$id': {'id': id, 'title': 't$id'},
      },
    };

    test(
      'write then read round-trips ids, entities, cursor and savedAt',
      () async {
        await store.write(
          'acct',
          'recommended',
          ids: const [3, 1, 2],
          entities: entitiesOf(const [3, 1, 2]),
          cursor: 'next-cursor',
        );

        final snapshot = await store.read('acct', 'recommended');
        expect(snapshot, isNotNull);
        expect(snapshot!.ids, [3, 1, 2]);
        expect(snapshot.entities['illust'], {
          '3': {'id': 3, 'title': 't3'},
          '1': {'id': 1, 'title': 't1'},
          '2': {'id': 2, 'title': 't2'},
        });
        expect(snapshot.cursor, 'next-cursor');
        expect(
          snapshot.savedAt.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
        );
        expect(snapshot.snapshotVersion, 1);
      },
    );

    test('read returns null on miss without counting a discard', () async {
      expect(await store.read('acct', 'missing'), isNull);
      expect(store.discardedCount, 0);
    });

    test('write upserts the same (account, feed) key', () async {
      await store.write(
        'acct',
        'feed',
        ids: const [1],
        entities: entitiesOf(const [1]),
        cursor: 'c1',
      );
      await store.write(
        'acct',
        'feed',
        ids: const [2],
        entities: entitiesOf(const [2]),
      );

      final snapshot = await store.read('acct', 'feed');
      expect(snapshot!.ids, [2]);
      expect(snapshot.cursor, isNull);
      expect(store.discardedCount, 0);
    });

    test('expired rows are discarded and deleted', () async {
      await store.write(
        'acct',
        'feed',
        ids: const [1],
        entities: entitiesOf(const [1]),
      );
      now = now.add(FeedSnapshotStore.maxAge + const Duration(minutes: 1));

      expect(await store.read('acct', 'feed'), isNull);
      expect(store.discardedCount, 1);

      // The row is gone: a second read stays a clean miss.
      now = now.subtract(FeedSnapshotStore.maxAge);
      expect(await store.read('acct', 'feed'), isNull);
      expect(store.discardedCount, 1);
    });

    test('corrupt payloads are discarded and deleted', () async {
      final db = await database.database;
      await db.insert(FeedDatabase.snapshotTable, {
        'account_id': 'acct',
        'feed_key': 'broken',
        'ids': 'not-json',
        'entities': '{broken',
        'saved_at': now.millisecondsSinceEpoch,
        'snapshot_version': 1,
      });

      expect(await store.read('acct', 'broken'), isNull);
      expect(store.discardedCount, 1);
    });

    test('snapshots are isolated per account', () async {
      await store.write(
        'a',
        'feed',
        ids: const [1],
        entities: entitiesOf(const [1]),
      );
      await store.write(
        'b',
        'feed',
        ids: const [2],
        entities: entitiesOf(const [2]),
      );

      expect((await store.read('a', 'feed'))!.ids, [1]);
      expect((await store.read('b', 'feed'))!.ids, [2]);
      expect(await store.read('c', 'feed'), isNull);
    });

    test('keeps only the newest maxEntriesPerAccount feeds', () async {
      store = FeedSnapshotStore(
        database: database,
        now: () => now,
        maxEntriesPerAccount: 4,
      );
      for (var i = 0; i < 6; i++) {
        await store.write(
          'acct',
          'feed-$i',
          ids: [i],
          entities: entitiesOf([i]),
        );
        now = now.add(const Duration(minutes: 1));
      }

      // Evicted rows are a clean miss, not a discard.
      expect(await store.read('acct', 'feed-0'), isNull);
      expect(await store.read('acct', 'feed-1'), isNull);
      for (var i = 2; i < 6; i++) {
        expect((await store.read('acct', 'feed-$i'))!.ids, [i]);
      }
      expect(store.discardedCount, 0);
    });

    test('clearAccount removes only that account\'s rows', () async {
      await store.write(
        'a',
        'feed',
        ids: const [1],
        entities: entitiesOf(const [1]),
      );
      await store.write(
        'b',
        'feed',
        ids: const [2],
        entities: entitiesOf(const [2]),
      );

      await store.clearAccount('a');

      expect(await store.read('a', 'feed'), isNull);
      expect((await store.read('b', 'feed'))!.ids, [2]);
    });
  });
}
