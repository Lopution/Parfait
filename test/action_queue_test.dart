import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_func/core/actionqueue/action_models.dart';
import 'package:pixiv_func/core/actionqueue/action_queue.dart';
import 'package:pixiv_func/core/actionqueue/action_store.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/paging/feed_database.dart';

class _Clock {
  DateTime now = DateTime.utc(2026, 9, 16, 12);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

class _Harness {
  _Harness() {
    store = InMemoryActionStore(now: clock.call);
    queue = ActionQueue(
      store: store,
      now: clock.call,
      cooldown: const Duration(seconds: 30),
      rowBackoff: const Duration(seconds: 10),
    );
  }

  final clock = _Clock();
  late final InMemoryActionStore store;
  late final ActionQueue queue;
  final handled = <String>[];
  final failures = <String, Queue<Object?>>{};

  void register(String type, {Object? Function(String dedupeKey)? errorFor}) {
    queue.registerHandler(type, (action) {
      handled.add('${action.type}:${action.decodePayload()['target']}');
      final error =
          errorFor?.call(action.dedupeKey) ??
          (failures[action.dedupeKey]?.isNotEmpty == true
              ? failures[action.dedupeKey]!.removeFirst()
              : null);
      if (error != null) throw error;
    });
  }

  Future<int> add(String owner, String type, String dedupeKey, int target) =>
      queue.enqueue(
        owner: owner,
        type: type,
        dedupeKey: dedupeKey,
        payload: {'target': target},
      );
}

void main() {
  group('ActionQueue engine', () {
    test('enqueue coalesces a pending row to the last intent', () async {
      final h = _Harness();
      await h.add('acc', 'bookmark.add', 'bookmark.add:1', 1);
      await h.add('acc', 'bookmark.delete', 'bookmark.add:1', 1);
      await h.add('acc', 'bookmark.add', 'bookmark.add:1', 42);

      final rows = await h.store.listFor('acc');
      expect(rows, hasLength(1));
      expect(rows.single.type, 'bookmark.add');
      expect(rows.single.decodePayload()['target'], 42);
      expect(rows.single.status, ActionStatus.pending);
    });

    test('drain replays ready rows serially in insertion order', () async {
      final h = _Harness()..register('t');
      await h.add('acc', 't', 'k:1', 1);
      await h.add('acc', 't', 'k:2', 2);
      await h.add('acc', 't', 'k:3', 3);

      await h.queue.drain('acc');

      expect(h.handled, ['t:1', 't:2', 't:3']);
      expect(await h.store.listFor('acc'), isEmpty);
      expect(h.queue.telemetry.replayed, 3);
    });

    test(
      'queue-cooldown failure returns the row and stops the drain',
      () async {
        final h = _Harness()..register('t');
        h.failures['k:1'] = Queue.of([const ApiNetworkError('offline')]);
        await h.add('acc', 't', 'k:1', 1);
        await h.add('acc', 't', 'k:2', 2);

        await h.queue.drain('acc');

        expect(h.handled, ['t:1']);
        final rows = await h.store.listFor('acc');
        expect(rows, hasLength(2));
        expect(rows.first.attempt, 0);
        expect(rows.first.status, ActionStatus.pending);

        // Still inside the cooldown window: nothing is attempted.
        h.clock.advance(const Duration(seconds: 10));
        await h.queue.drain('acc');
        expect(h.handled, hasLength(1));

        // Past cooldown: both rows replay; the first succeeds this time
        // because the scripted error fired only once.
        h.clock.advance(const Duration(seconds: 30));
        // errorFor fired already; second call returns null.
        await h.queue.drain('acc');
        expect(h.handled, ['t:1', 't:1', 't:2']);
        expect(await h.store.listFor('acc'), isEmpty);
        expect(h.queue.telemetry.replayed, 2);
      },
    );

    test('rate-limit retryAfter overrides the default cooldown', () async {
      final h = _Harness()
        ..register(
          't',
          errorFor: (key) => const ApiRateLimited(Duration(seconds: 90)),
        );
      await h.add('acc', 't', 'k:1', 1);

      await h.queue.drain('acc');
      h.clock.advance(const Duration(seconds: 60));
      await h.queue.drain('acc');
      expect(h.handled, hasLength(1));

      h.clock.advance(const Duration(seconds: 40));
      // errorFor throws every call here, so gate on handled count growth.
      // After the hint window passes the row is attempted again (and fails
      // again — the point is the queue un-paused).
      await h.queue.drain('acc');
      expect(h.handled, hasLength(2));
    });

    test('row-scope failure backs off only that row', () async {
      final h = _Harness()
        ..register(
          't',
          errorFor: (key) => key == 'k:1' ? const ApiHttpError(403) : null,
        );
      await h.add('acc', 't', 'k:1', 1);
      await h.add('acc', 't', 'k:2', 2);

      await h.queue.drain('acc');

      // Row retry does not stop the queue — k:2 still replayed.
      expect(h.handled, ['t:1', 't:2']);
      final rows = await h.store.listFor('acc');
      expect(rows, hasLength(1));
      expect(rows.single.dedupeKey, 'k:1');
      expect(rows.single.attempt, 1);
      expect(rows.single.nextAttemptAt, isNotNull);

      // Before the row backoff elapses it is skipped entirely.
      await h.queue.drain('acc');
      expect(h.handled, hasLength(2));

      h.clock.advance(const Duration(seconds: 11));
      await h.queue.drain('acc');
      expect(h.handled, hasLength(3));
    });

    test(
      'a row is marked failed after maxAttempts and counted dropped',
      () async {
        final h = _Harness()
          ..register('t', errorFor: (key) => const ApiHttpError(403));
        await h.add('acc', 't', 'k:1', 1);

        for (var i = 0; i < 5; i++) {
          await h.queue.drain('acc');
          h.clock.advance(const Duration(minutes: 1));
        }

        final rows = await h.store.listFor('acc');
        expect(rows.single.status, ActionStatus.failed);
        expect(h.queue.telemetry.dropped, 1);
        // Failed rows are never picked up again.
        await h.queue.drain('acc');
        expect(h.handled, hasLength(5));
      },
    );

    test('drain never touches another owner\'s rows', () async {
      final h = _Harness()..register('t');
      await h.add('acc-a', 't', 'k:1', 1);
      await h.add('acc-b', 't', 'k:1', 2);

      await h.queue.drain('acc-a');

      expect(h.handled, ['t:1']);
      final b = await h.store.listFor('acc-b');
      expect(b.single.status, ActionStatus.pending);
    });

    test('a row without a registered handler is dropped visibly', () async {
      final h = _Harness();
      await h.add('acc', 'ghost.type', 'ghost:1', 1);

      await h.queue.drain('acc');

      final rows = await h.store.listFor('acc');
      expect(rows.single.status, ActionStatus.failed);
      expect(h.queue.telemetry.dropped, 1);
    });

    test('re-entrant drain calls coalesce into the running drain', () async {
      final h = _Harness();
      h.queue.registerHandler('t', (action) async {
        h.handled.add('t:${action.id}');
        if (action.id == 1) {
          // Re-enter drain while running — must not double-drive rows.
          await h.queue.drain('acc');
        }
      });
      await h.add('acc', 't', 'k:1', 1);
      await h.add('acc', 't', 'k:2', 2);

      await h.queue.drain('acc');
      expect(h.handled, ['t:1', 't:2']);
    });
  });

  group('SqliteActionStore', () {
    late FeedDatabase database;
    late Directory directory;
    late SqliteActionStore store;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('pixiv-aq-test-');
      database = FeedDatabase(
        factory: databaseFactoryFfi,
        databasePath: path.join(directory.path, 'feeds.db'),
      );
      store = SqliteActionStore(database: database);
    });

    tearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });

    test('enqueue/nextReady/markPending round-trip through sqlite', () async {
      final queue = ActionQueue(store: store, now: DateTime.now);
      final id = await queue.enqueue(
        owner: 'acc',
        type: 'follow.add',
        dedupeKey: 'follow:7',
        payload: {'user': 7},
      );

      final ready = await store.nextReady('acc', 0);
      expect(ready, isNotNull);
      expect(ready!.id, id);
      expect(ready.status, ActionStatus.pending);
      expect(ready.decodePayload()['user'], 7);

      await store.markRunning(id);
      expect(await store.nextReady('acc', 1 << 62), isNull);

      final farFuture = DateTime.utc(2100).millisecondsSinceEpoch;
      await store.markPending(id, attempt: 2, nextAttemptAtMs: farFuture);
      expect(await store.nextReady('acc', 0), isNull);
      expect(await store.nextReady('acc', farFuture), isNotNull);

      // Coalesce replaces the pending row with a fresh id.
      final id2 = await queue.enqueue(
        owner: 'acc',
        type: 'follow.delete',
        dedupeKey: 'follow:7',
        payload: {'user': 7},
      );
      expect(id2, isNot(id));
      final rows = await store.listFor('acc');
      expect(rows, hasLength(1));
      expect(rows.single.type, 'follow.delete');
      expect(rows.single.attempt, 0);
    });
  });
}
