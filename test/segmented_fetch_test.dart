import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/segmented_fetch.dart';

const _mib = 1 << 20;

/// How the fake server streams one request's body.
class _Plan {
  const _Plan({
    this.chunk = 64 * 1024,
    this.interval = const Duration(milliseconds: 10),
    this.stallAt,
    this.failAt,
    this.status = 206,
    this.shiftRange = 0,
  });

  /// About 6.4 MB/s.
  static const fast = _Plan();

  /// 10 KB/s.
  static const slow = _Plan(chunk: 10 * 1000, interval: Duration(seconds: 1));

  final int chunk;
  final Duration interval;

  /// Stops sending, without closing, after this many bytes.
  final int? stallAt;

  /// Fails the body with a socket-style error after this many bytes.
  final int? failAt;
  final int status;

  /// Misreports the served range's start by this many bytes.
  final int shiftRange;
}

typedef _Request = ({int start, int end, String? ifRange});

/// The network boundary: serves byte ranges of [data] from memory, paced in
/// fake time by a per-request [_Plan].
class _Server {
  _Server(int size, {this.etag})
    : data = Uint8List.fromList([for (var i = 0; i < size; i++) i * 31 % 251]);

  final Uint8List data;
  final String? etag;
  final requests = <_Request>[];
  _Plan Function(_Request request, int nth) plan = (_, _) => _Plan.fast;
  var openConnections = 0;
  var peakConnections = 0;

  int get total => data.length;

  /// Requests that started inside the segment beginning at [segmentStart].
  int attemptsFor(int segmentStart, int segmentBytes) => requests
      .where(
        (r) => r.start >= segmentStart && r.start < segmentStart + segmentBytes,
      )
      .length;

  Future<RangeResponse> open(
    int start,
    int end, {
    String? ifRange,
    required NetworkCancelSignal cancel,
  }) async {
    final request = (start: start, end: end, ifRange: ifRange);
    requests.add(request);
    final nth = requests.where((r) => r.start == start).length;
    final plan = this.plan(request, nth);
    final last = math.min(end, total - 1);
    final bytes = Uint8List.sublistView(data, start, last + 1);
    openConnections++;
    peakConnections = math.max(peakConnections, openConnections);
    var open = true;
    void hangUp() {
      if (!open) return;
      open = false;
      openConnections--;
    }

    Timer? timer;
    late final StreamController<List<int>> body;
    var sent = 0;
    body = StreamController<List<int>>(
      onListen: () => timer = Timer.periodic(plan.interval, (_) {
        if (plan.failAt case final failAt? when sent >= failAt) {
          timer?.cancel();
          body.addError(const _Reset());
          hangUp();
          return;
        }
        if (plan.stallAt case final stallAt? when sent >= stallAt) return;
        final n = math.min(plan.chunk, bytes.length - sent);
        body.add(Uint8List.sublistView(bytes, sent, sent + n));
        sent += n;
        if (sent >= bytes.length) {
          timer?.cancel();
          body.close();
          hangUp();
        }
      }),
      onCancel: () {
        timer?.cancel();
        hangUp();
      },
    );
    return RangeResponse(
      statusCode: plan.status,
      headers: {
        'content-range':
            'bytes ${start + plan.shiftRange}-${last + plan.shiftRange}/$total',
        'etag': ?etag,
      },
      body: body.stream,
      close: () async {
        timer?.cancel();
        hangUp();
      },
    );
  }
}

class _Reset implements Exception {
  const _Reset();
}

class _Cancel implements NetworkCancelSignal {
  final _completer = Completer<void>();
  @override
  bool get isCancelled => _completer.isCompleted;
  @override
  Future<void> get whenCancel => _completer.future;
  void cancel() => _completer.complete();
}

/// One segmented transfer of [server] in fake time.
class _Run {
  _Run(
    this.async,
    this.server, {
    SegmentBudget? budget,
    int maxParallel = SegmentedFetch.defaultParallel,
    this.cancel,
  }) : budget = budget ?? SegmentBudget() {
    final start = DateTime(2026, 10, 3);
    fetch = SegmentedFetch(
      open: server.open,
      budget: this.budget,
      maxParallel: maxParallel,
      clock: () => start.add(async.elapsed),
    );
    server
        .open(0, SegmentedFetch.defaultSegmentBytes - 1, cancel: _Cancel())
        .then((first) {
          subscription = fetch
              .continueFrom(first, cancel: cancel)
              .listen(
                bytes.add,
                onError: (Object e) => error = e,
                onDone: () => done = true,
              );
        });
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final _Server server;
  final SegmentBudget budget;
  final NetworkCancelSignal? cancel;
  late final SegmentedFetch fetch;
  late StreamSubscription<List<int>> subscription;
  final bytes = BytesBuilder(copy: false);
  var done = false;
  Object? error;

  void expectComplete() {
    expect(error, isNull);
    expect(done, isTrue);
    final got = bytes.takeBytes();
    expect(got.length, server.total);
    var firstDiff = -1;
    for (var i = 0; i < got.length && firstDiff < 0; i++) {
      if (got[i] != server.data[i]) firstDiff = i;
    }
    expect(firstDiff, -1, reason: 'first differing byte');
    expect(server.openConnections, 0);
    expect(budget.inUse, 0);
  }
}

void main() {
  for (final size in [1, _mib - 1, _mib, _mib + 1, 10 * _mib + _mib ~/ 2]) {
    test('reassembles $size bytes in order', () {
      fakeAsync((async) {
        final run = _Run(async, _Server(size));
        async.elapse(const Duration(seconds: 30));
        run.expectComplete();
        expect(run.fetch.fetchedBytes, size);
      });
    });
  }

  test('a budget of 2 caps the transfer at 3 connections', () {
    fakeAsync((async) {
      final server = _Server(10 * _mib);
      final run = _Run(async, server, budget: SegmentBudget(limit: 2));
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
      expect(server.peakConnections, 3);
    });
  });

  test('with no budget left the first connection does it all', () {
    fakeAsync((async) {
      final server = _Server(4 * _mib);
      final run = _Run(async, server, budget: SegmentBudget(limit: 0));
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
      expect(server.peakConnections, 1);
    });
  });

  test('a slow segment restarts from the byte it reached', () {
    fakeAsync((async) {
      final server = _Server(8 * _mib)
        ..plan = (r, nth) =>
            r.start == _mib && nth == 1 ? _Plan.slow : _Plan.fast;
      final run = _Run(async, server);
      async.elapse(const Duration(seconds: 2));
      expect(server.attemptsFor(_mib, _mib), 1);
      async.elapse(const Duration(seconds: 3));
      final retries = server.requests.where(
        (r) => r.start > _mib && r.start < 2 * _mib,
      );
      expect(retries, hasLength(1));
      // 10 KB a second for about four seconds.
      expect(
        retries.single.start,
        inInclusiveRange(_mib + 20000, _mib + 50000),
      );
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
    });
  });

  test('a stalled segment restarts after 5 s without bytes', () {
    fakeAsync((async) {
      // 172 KiB left after the stall: too little for a slow restart, so
      // only the stall rule can fire.
      final server = _Server(2 * _mib + 300 * 1024)
        ..plan = (r, nth) => r.start == 2 * _mib && nth == 1
            ? const _Plan(stallAt: 128 * 1024)
            : _Plan.fast;
      final run = _Run(async, server);
      async.elapse(const Duration(seconds: 4));
      expect(server.attemptsFor(2 * _mib, _mib), 1);
      async.elapse(const Duration(seconds: 3));
      expect(server.requests.last.start, 2 * _mib + 128 * 1024);
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
    });
  });

  test('a segment restarts at most twice, then waits', () {
    fakeAsync((async) {
      final server = _Server(3 * _mib)
        ..plan = (r, _) => r.start >= 2 * _mib
            ? _Plan(stallAt: r.start == 2 * _mib ? 1024 : 0)
            : _Plan.fast;
      final run = _Run(async, server);
      async.elapse(const Duration(minutes: 2));
      expect(
        server.attemptsFor(2 * _mib, _mib),
        1 + SegmentedFetch.maxRestarts,
      );
      expect(run.done, isFalse);
      expect(run.error, isNull);
      run.subscription.cancel();
      async.flushMicrotasks();
      expect(server.openConnections, 0);
      expect(run.budget.inUse, 0);
    });
  });

  test('a dropped connection resumes; the third drop fails the transfer', () {
    fakeAsync((async) {
      final server = _Server(3 * _mib)
        ..plan = (r, _) => r.start >= _mib && r.start < 2 * _mib
            ? const _Plan(failAt: 64 * 1024)
            : _Plan.fast;
      final run = _Run(async, server);
      async.elapse(const Duration(seconds: 30));
      expect(server.attemptsFor(_mib, _mib), 1 + SegmentedFetch.maxRestarts);
      expect(
        server.requests.where((r) => r.start > _mib && r.start < 2 * _mib),
        hasLength(SegmentedFetch.maxRestarts),
      );
      expect(run.error, isA<_Reset>());
      expect(server.openConnections, 0);
      expect(run.budget.inUse, 0);
    });
  });

  test('every segment asks If-Range with the first ETag', () {
    fakeAsync((async) {
      final server = _Server(3 * _mib, etag: '"abc"');
      final run = _Run(async, server);
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
      expect(
        server.requests.skip(1).map((r) => r.ifRange),
        everyElement('"abc"'),
      );
    });
  });

  for (final (name, plan) in [
    ('a 200', const _Plan(status: 200)),
    ('a shifted range', const _Plan(shiftRange: 1)),
  ]) {
    test('$name for a segment fails the transfer without a retry', () {
      fakeAsync((async) {
        final server = _Server(3 * _mib)
          ..plan = (r, _) => r.start == 2 * _mib ? plan : _Plan.fast;
        final run = _Run(async, server);
        async.elapse(const Duration(seconds: 30));
        expect(run.error, isA<SegmentedFetchMismatch>());
        expect(server.attemptsFor(2 * _mib, _mib), 1);
        expect(server.openConnections, 0);
        expect(run.budget.inUse, 0);
      });
    });
  }

  test('cancelling closes every connection and returns the budget', () {
    fakeAsync((async) {
      final server = _Server(10 * _mib)..plan = (_, _) => _Plan.slow;
      final cancel = _Cancel();
      final run = _Run(async, server, cancel: cancel);
      async.elapse(const Duration(seconds: 1));
      expect(server.openConnections, SegmentedFetch.defaultParallel);
      cancel.cancel();
      async.flushMicrotasks();
      expect(run.error, isA<SegmentedFetchCancelled>());
      expect(server.openConnections, 0);
      expect(run.budget.inUse, 0);
    });
  });

  test('a paused reader stops new segments; resuming finishes', () {
    fakeAsync((async) {
      final server = _Server(10 * _mib);
      final run = _Run(async, server);
      run.subscription.pause();
      async.elapse(const Duration(seconds: 10));
      // Only the window of segments past the undelivered one is fetched.
      expect(server.requests, hasLength(SegmentedFetch.defaultParallel));
      run.subscription.resume();
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
    });
  });
}
