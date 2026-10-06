import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/image/image_fetch_scheduler.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';

/// A scheduler whose `execute` is an in-memory gate: every admitted URL
/// gets a completer the test resolves explicitly, so "streaming" fetches
/// stay open exactly as long as the test wants.
class _Harness {
  _Harness({int foreground = 8, int background = 2}) {
    scheduler = ImageFetchScheduler<String>(
      foregroundSlots: foreground,
      backgroundSlots: background,
      execute: (url) {
        started.add(url);
        final completer = Completer<String>();
        pending[url] = completer;
        return completer.future;
      },
    );
  }

  late final ImageFetchScheduler<String> scheduler;
  final started = <String>[];
  final pending = <String, Completer<String>>{};

  void finish(String url, [String result = 'ok']) {
    pending.remove(url)!.complete(result);
  }

  void fail(String url, Object error) {
    pending.remove(url)!.completeError(error);
  }
}

/// Synchronous capture of a future's outcome. Async matchers like
/// `throwsA`/`completion` must not be used inside `fakeAsync` — the
/// framework keeps waiting on them after the zone stops pumping
/// microtasks, which hangs the test.
class _Capture<T> {
  _Capture(Future<T> future) {
    future.then(
      (result) {
        value = result;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
  }

  T? value;
  Object? error;
  var done = false;
}

void main() {
  test('requests for the same URL share one flight and one result', () {
    fakeAsync((async) {
      final harness = _Harness();
      final a = _Capture(
        harness.scheduler.submit(
          1,
          'a',
          priority: ImageFetchPriority.background,
        ),
      );
      final b = _Capture(
        harness.scheduler.submit(
          2,
          'a',
          priority: ImageFetchPriority.background,
        ),
      );
      async.flushMicrotasks();
      expect(harness.started, ['a']);

      harness.finish('a', 'bytes');
      async.flushMicrotasks();
      expect(a.value, 'bytes');
      expect(b.value, 'bytes');
    });
  });

  test('lane caps hold; a finished transfer admits the next waiter', () {
    fakeAsync((async) {
      final harness = _Harness(foreground: 2, background: 1);
      harness.scheduler
        ..submit(1, 'f1', priority: ImageFetchPriority.foreground)
        ..submit(2, 'f2', priority: ImageFetchPriority.foreground)
        ..submit(3, 'f3', priority: ImageFetchPriority.foreground)
        ..submit(4, 'b1', priority: ImageFetchPriority.background)
        ..submit(5, 'b2', priority: ImageFetchPriority.background);
      async.flushMicrotasks();
      expect(harness.started, containsAllInOrder(['f1', 'f2', 'b1']));
      expect(harness.scheduler.inFlight, 3);
      expect(harness.scheduler.queued, 2);

      harness.finish('b1');
      async.flushMicrotasks();
      expect(harness.started.last, 'b2');
      harness.finish('f1');
      async.flushMicrotasks();
      expect(harness.started.last, 'f3');
    });
  });

  test('a foreground interest promotes a queued background fetch', () {
    fakeAsync((async) {
      final harness = _Harness(foreground: 1, background: 1);
      // Occupy both lanes; queue a background fetch behind them.
      harness.scheduler
        ..submit(1, 'bg', priority: ImageFetchPriority.background)
        ..submit(2, 'fg', priority: ImageFetchPriority.foreground);
      final queued = _Capture(
        harness.scheduler.submit(
          3,
          'warm',
          priority: ImageFetchPriority.background,
        ),
      );
      async.flushMicrotasks();
      expect(harness.started, isNot(contains('warm')));

      // A visible request for the same URL promotes it onto the
      // foreground lane — it overtakes other background waiters.
      harness.scheduler.submit(
        4,
        'bg2',
        priority: ImageFetchPriority.background,
      );
      final visible = _Capture(
        harness.scheduler.submit(
          5,
          'warm',
          priority: ImageFetchPriority.foreground,
        ),
      );
      async.flushMicrotasks();
      expect(harness.started, isNot(contains('warm')));

      harness.finish('fg');
      async.flushMicrotasks();
      expect(harness.started.last, 'warm');
      harness.finish('warm');
      async.flushMicrotasks();
      expect(queued.done && visible.done, isTrue);
      // The promoted fetch is done; 'bg2' still waits behind 'bg' on the
      // background lane — it only runs once 'bg' finishes.
      harness.finish('bg');
      async.flushMicrotasks();
      expect(harness.started.last, 'bg2');
    });
  });

  test('a cancelled queued request drops after the grace window', () {
    fakeAsync((async) {
      final harness = _Harness(foreground: 1, background: 1);
      harness.scheduler
        ..submit(1, 'fg', priority: ImageFetchPriority.foreground)
        ..submit(2, 'bg', priority: ImageFetchPriority.background);
      final dead = _Capture(
        harness.scheduler.submit(
          3,
          'warm',
          priority: ImageFetchPriority.background,
        ),
      );
      async.flushMicrotasks();

      // The caller fails at once when cancelled, not after the grace.
      harness.scheduler.cancel(3);
      async.flushMicrotasks();
      expect(dead.error, isA<ImageFetchDropped>());
      expect(harness.scheduler.queued, 1); // still holding queue position

      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      expect(harness.scheduler.queued, 0);
      expect(harness.started, isNot(contains('warm')));

      // The freed queue position admits the next waiter once a lane slot
      // opens — the drop leaked nothing.
      harness.scheduler.submit(
        4,
        'next',
        priority: ImageFetchPriority.background,
      );
      async.flushMicrotasks();
      expect(harness.scheduler.queued, 1);
      harness.finish('bg');
      async.flushMicrotasks();
      expect(harness.started.last, 'next');
    });
  });

  test('a request re-submitted inside the grace keeps its place', () {
    fakeAsync((async) {
      final harness = _Harness(foreground: 0, background: 1);
      harness.scheduler.submit(
        1,
        'bg',
        priority: ImageFetchPriority.background,
      );
      final gone = _Capture(
        harness.scheduler.submit(
          2,
          'warm',
          priority: ImageFetchPriority.background,
        ),
      );
      async.flushMicrotasks();
      harness.scheduler.cancel(2);
      async.flushMicrotasks();
      expect(gone.error, isA<ImageFetchDropped>());

      // A new interest for the same URL lands within the grace window:
      // the queued fetch lives on instead of dropping to the queue tail.
      final reborn = _Capture(
        harness.scheduler.submit(
          3,
          'warm',
          priority: ImageFetchPriority.background,
        ),
      );
      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      expect(harness.scheduler.queued, 1);

      harness.finish('bg');
      async.flushMicrotasks();
      expect(harness.started.last, 'warm');
      harness.finish('warm');
      async.flushMicrotasks();
      expect(reborn.value, 'ok');
    });
  });

  test('a transfer already streaming is never interrupted by a cancel', () {
    fakeAsync((async) {
      final harness = _Harness(foreground: 1, background: 1);
      final streaming = _Capture(
        harness.scheduler.submit(
          1,
          'fg',
          priority: ImageFetchPriority.foreground,
        ),
      );
      async.flushMicrotasks();
      expect(harness.started, ['fg']);

      harness.scheduler.cancel(1);
      async.flushMicrotasks();
      expect(streaming.error, isA<ImageFetchDropped>());
      async.elapse(const Duration(seconds: 1));
      // The flight continues to completion for the disk cache — the gate
      // is released only when the transfer ends.
      expect(harness.scheduler.inFlight, 1);
      harness.finish('fg');
      async.flushMicrotasks();
      expect(harness.scheduler.inFlight, 0);
    });
  });

  test('a cancel after the result is a no-op', () {
    fakeAsync((async) {
      final harness = _Harness();
      final done = _Capture(
        harness.scheduler.submit(
          1,
          'a',
          priority: ImageFetchPriority.foreground,
        ),
      );
      async.flushMicrotasks();
      harness.finish('a', 'bytes');
      async.flushMicrotasks();
      expect(done.value, 'bytes');

      // The provider cancels when its listener leaves, which may be after
      // the worker answered; the settled id must not complete twice.
      harness.scheduler.cancel(1);
      async.flushMicrotasks();
      expect(done.error, isNull);

      // A later request for the URL starts a fresh flight.
      harness.scheduler.submit(2, 'a', priority: ImageFetchPriority.foreground);
      async.flushMicrotasks();
      expect(harness.started, ['a', 'a']);
    });
  });

  test('an execute error reaches every interest on the flight', () {
    fakeAsync((async) {
      final harness = _Harness();
      final a = _Capture(
        harness.scheduler.submit(
          1,
          'x',
          priority: ImageFetchPriority.foreground,
        ),
      );
      final b = _Capture(
        harness.scheduler.submit(
          2,
          'x',
          priority: ImageFetchPriority.foreground,
        ),
      );
      async.flushMicrotasks();
      harness.fail('x', StateError('boom'));
      async.flushMicrotasks();
      expect(a.error, isA<StateError>());
      expect(b.error, isA<StateError>());
      expect(harness.scheduler.inFlight, 0);
    });
  });

  test('a queued fetch nobody wants is dropped at its turn', () {
    fakeAsync((async) {
      final harness = _Harness(foreground: 0, background: 1);
      harness.scheduler.submit(
        1,
        'bg',
        priority: ImageFetchPriority.background,
      );
      final dead = _Capture(
        harness.scheduler.submit(
          2,
          'warm',
          priority: ImageFetchPriority.background,
        ),
      );
      async.flushMicrotasks();
      // The caller already left; the gate must not hand it the freed slot.
      harness.scheduler.cancel(2);
      async.flushMicrotasks();
      expect(dead.error, isA<ImageFetchDropped>());
      harness.finish('bg');
      async.flushMicrotasks();
      expect(harness.started, isNot(contains('warm')));

      harness.scheduler.submit(
        3,
        'next',
        priority: ImageFetchPriority.background,
      );
      async.flushMicrotasks();
      expect(harness.started.last, 'next');
    });
  });
}
