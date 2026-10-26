import 'dart:collection';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:parfait/core/actionqueue/action_models.dart';
import 'package:parfait/core/actionqueue/action_queue.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/paging/feed_database.dart';

class _Clock {
  DateTime now = DateTime.utc(2026, 9, 16, 12);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

class _Harness {
  /// [now] replaces the manual [clock], e.g. with a fake_async clock;
  /// [wrap] puts a store in front of the in-memory one.
  _Harness({
    DateTime Function()? now,
    ActionStore Function(InMemoryActionStore)? wrap,
  }) {
    store = InMemoryActionStore(now: now ?? clock.call);
    queue = ActionQueue(
      store: wrap?.call(store) ?? store,
      now: now ?? clock.call,
      cooldown: const Duration(seconds: 30),
      rowBackoff: const Duration(seconds: 10),
    );
    addTearDown(queue.dispose);
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

/// Fails its first recovery, as a locked database did in the field.
final class _BusyOnceStore implements ActionStore {
  _BusyOnceStore(this._inner);

  final InMemoryActionStore _inner;
  var _busy = true;

  @override
  Future<({int reset, int dropped})> recoverInterrupted() async {
    if (!_busy) return _inner.recoverInterrupted();
    _busy = false;
    throw StateError('database is locked');
  }

  @override
  Future<int> enqueue(StoredAction draft) => _inner.enqueue(draft);
  @override
  Future<StoredAction?> nextReady(String owner, int nowMs) =>
      _inner.nextReady(owner, nowMs);
  @override
  Future<bool> markRunning(int id) => _inner.markRunning(id);
  @override
  Future<void> markPending(int id, {int? attempt, int? nextAttemptAtMs}) =>
      _inner.markPending(
        id,
        attempt: attempt,
        nextAttemptAtMs: nextAttemptAtMs,
      );
  @override
  Future<void> markFailed(int id) => _inner.markFailed(id);
  @override
  Future<void> delete(int id) => _inner.delete(id);
  @override
  Future<bool> deletePending(String owner, String dedupeKey) =>
      _inner.deletePending(owner, dedupeKey);
  @override
  Future<int?> nextPendingAt(String owner) => _inner.nextPendingAt(owner);
  @override
  Future<List<StoredAction>> listFor(String owner) => _inner.listFor(owner);
  @override
  Future<void> clearAccount(String owner) => _inner.clearAccount(owner);
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

    test('a dropped pending row never replays, even if already read', () async {
      final h = _Harness()..register('bookmark.add');
      final id = await h.add('acc', 'bookmark.add', 'bookmark:1', 1);
      await h.add('acc', 'bookmark.add', 'bookmark:2', 2);

      final stale = await h.store.nextReady('acc', 0);
      expect(stale!.id, id);
      expect(
        await h.queue.dropPending(owner: 'acc', dedupeKey: 'bookmark:1'),
        isTrue,
      );
      expect(await h.store.markRunning(id), isFalse, reason: 'claim fails');
      expect(
        await h.queue.dropPending(owner: 'acc', dedupeKey: 'bookmark:1'),
        isFalse,
      );

      await h.queue.drain('acc');
      expect(h.handled, ['bookmark.add:2']);
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

    test(
      'the first drain replays interrupted rows; newer intents win',
      () async {
        final h = _Harness();
        final interrupted = await h.add('acc', 't', 'k:1', 1);
        final superseded = await h.add('acc', 't', 'k:2', 2);
        // A previous process was killed mid-replay of both rows, then the
        // user tapped k:2 again before this process drained.
        await h.store.markRunning(interrupted);
        await h.store.markRunning(superseded);
        await h.add('acc', 't', 'k:2', 3);

        h.register('t');
        await h.queue.drain('acc');

        expect(h.handled, ['t:1', 't:3']);
        expect(await h.store.listFor('acc'), isEmpty);
      },
    );

    test('cooldown, backoff and a fresh enqueue wake the queue', () {
      fakeAsync((async) {
        final h = _Harness(now: async.getClock(DateTime.utc(2026, 10)).now)
          ..register('t');
        h.failures['k:1'] = Queue.of([const ApiNetworkError('offline')]);
        h.failures['k:2'] = Queue.of([const ApiHttpError(403)]);

        // Nothing drains after an enqueue: it wakes one cooldown later.
        h.add('acc', 't', 'k:1', 1);
        async.elapse(const Duration(seconds: 29));
        expect(h.handled, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(h.handled, ['t:1'], reason: 'offline: queue cools down');

        async.elapse(const Duration(seconds: 30));
        expect(h.handled, ['t:1', 't:1'], reason: 'cooldown over: replayed');

        h.add('acc', 't', 'k:2', 2);
        async.flushMicrotasks();
        h.queue.drain('acc');
        async.flushMicrotasks();
        expect(h.handled.last, 't:2', reason: 'rejected: row backs off 10s');
        async.elapse(const Duration(seconds: 10));
        expect(h.handled, ['t:1', 't:1', 't:2', 't:2']);
      });
    });

    test('a failed recovery wakes the queue itself one cooldown later', () {
      fakeAsync((async) {
        final h = _Harness(
          now: async.getClock(DateTime.utc(2026, 10)).now,
          wrap: _BusyOnceStore.new,
        )..register('t');
        // A row the last process left running: no enqueue armed a wake for
        // it, and only a recovery makes it ready again.
        var running = false;
        h.store
            .enqueue(
              const StoredAction(
                id: 0,
                owner: 'acc',
                type: 't',
                dedupeKey: 'k:1',
                payload: '{"target":1}',
                status: ActionStatus.pending,
                attempt: 0,
                createdAt: 0,
              ),
            )
            .then(h.store.markRunning)
            .then((marked) => running = marked);
        async.flushMicrotasks();
        expect(running, isTrue);
        Object? failure;
        h.queue.drain('acc').catchError((Object e) => failure = e);
        async.flushMicrotasks();
        expect(failure, isA<StateError>());
        expect(h.handled, isEmpty);

        async.elapse(const Duration(seconds: 30));
        expect(h.handled, ['t:1']);
      });
    });

    test('retryNow skips the cooldown; a parked owner stays asleep', () {
      fakeAsync((async) {
        final h = _Harness(now: async.getClock(DateTime.utc(2026, 10)).now)
          ..register('t');
        h.failures['k:1'] = Queue.of([
          const ApiNetworkError('offline'),
          const ApiNetworkError('offline'),
        ]);
        h.add('acc', 't', 'k:1', 1);
        async.flushMicrotasks();
        h.queue.drain('acc');
        async.flushMicrotasks();
        h.queue.retryNow('acc');
        async.flushMicrotasks();
        expect(h.handled, ['t:1', 't:1']);

        // The account was switched away from: its wake must not fire.
        h.queue.park('acc');
        async.elapse(const Duration(minutes: 5));
        expect(h.handled, hasLength(2));

        h.queue.drain('acc');
        async.flushMicrotasks();
        expect(h.handled, hasLength(3), reason: 'an explicit drain resumes');
      });
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

      expect(await store.markRunning(id), isTrue);
      expect(await store.markRunning(id), isFalse, reason: 'already claimed');
      expect(await store.nextReady('acc', 1 << 62), isNull);
      expect(
        await store.deletePending('acc', 'follow:7'),
        isFalse,
        reason: 'a running row stays for its replay to finish',
      );

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

      expect(await store.deletePending('acc', 'follow:7'), isTrue);
      expect(await store.listFor('acc'), isEmpty);
    });

    test('recoverInterrupted and nextPendingAt through sqlite', () async {
      final queue = ActionQueue(store: store, now: DateTime.now);
      addTearDown(queue.dispose);
      Future<int> follow(int user, String type) => queue.enqueue(
        owner: 'acc',
        type: type,
        dedupeKey: 'follow:$user',
        payload: {'user': user},
      );
      final interrupted = await follow(7, 'follow.add');
      final superseded = await follow(8, 'follow.add');
      await store.markPending(interrupted, attempt: 2, nextAttemptAtMs: 5);
      await store.markRunning(interrupted);
      await store.markRunning(superseded);
      final newer = await follow(8, 'follow.delete');

      expect(await store.recoverInterrupted(), (reset: 1, dropped: 1));
      final rows = await store.listFor('acc');
      expect([for (final row in rows) row.id], [interrupted, newer]);
      expect(rows.first.status, ActionStatus.pending);
      expect(rows.first.attempt, 2);

      expect(await store.nextPendingAt('acc'), 0, reason: 'newer is ready');
      await store.delete(newer);
      expect(await store.nextPendingAt('acc'), 5);
      await store.markFailed(interrupted);
      expect(await store.nextPendingAt('acc'), isNull);
    });
  });
}
