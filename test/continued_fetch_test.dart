import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/continued_fetch.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';

const _mib = 1 << 20;

/// How the fake server streams one request's body.
class _Plan {
  const _Plan({
    this.chunk = 64 * 1024,
    this.interval = const Duration(milliseconds: 10),
    this.stallAt,
    this.failAt,
    this.endAt,
    this.status = 206,
    this.shiftRange = 0,
  });

  /// About 6.4 MB/s.
  static const fast = _Plan();

  final int chunk;
  final Duration interval;

  /// Stops sending, without closing, after this many bytes.
  final int? stallAt;

  /// Fails the body with a socket-style error after this many bytes.
  final int? failAt;

  /// Ends the body normally, short of the file, after this many bytes.
  final int? endAt;
  final int status;

  /// Misreports the served range's start by this many bytes.
  final int shiftRange;
}

typedef _Request = ({int start, String? ifRange, bool elsewhere});

/// The network boundary: serves [data] from a byte to its end, paced in
/// fake time by a per-request [_Plan].
class _Server {
  _Server(int size, {this.etag})
    : data = Uint8List.fromList([for (var i = 0; i < size; i++) i * 31 % 251]);

  final Uint8List data;
  final String? etag;
  final requests = <_Request>[];

  /// The plan of the [nth] request (0 is the first).
  _Plan Function(int nth) plan = (_) => _Plan.fast;
  var openConnections = 0;
  var peakConnections = 0;

  int get total => data.length;

  Future<RangeResponse> open(
    int start, {
    String? ifRange,
    required NetworkCancelSignal cancel,
    bool elsewhere = false,
  }) async {
    final plan = this.plan(requests.length);
    requests.add((start: start, ifRange: ifRange, elsewhere: elsewhere));
    final bytes = plan.status == 200
        ? data
        : Uint8List.sublistView(data, start);
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
        if (plan.endAt case final endAt? when sent >= endAt) {
          timer?.cancel();
          unawaited(body.close());
          hangUp();
          return;
        }
        if (plan.stallAt case final stallAt? when sent >= stallAt) return;
        final n = math.min(plan.chunk, bytes.length - sent);
        body.add(Uint8List.sublistView(bytes, sent, sent + n));
        sent += n;
        if (sent >= bytes.length) {
          timer?.cancel();
          unawaited(body.close());
          hangUp();
        }
      }),
      onCancel: () {
        timer?.cancel();
        hangUp();
      },
    );
    final shown = start + plan.shiftRange;
    return RangeResponse(
      statusCode: plan.status,
      headers: {
        if (plan.status == 206)
          'content-range': 'bytes $shown-${total - 1}/$total',
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

/// One continued transfer of [server] in fake time.
class _Run {
  _Run(this.async, this.server, {this.cancel}) {
    final start = DateTime(2026, 11, 4);
    fetch = ContinuedFetch(
      open: server.open,
      clock: () => start.add(async.elapsed),
    );
    unawaited(
      server.open(0, cancel: _Cancel()).then((first) {
        subscription = fetch
            .continueFrom(first, cancel: cancel)
            .listen(
              bytes.add,
              onError: (Object e) => error = e,
              onDone: () => done = true,
            );
      }),
    );
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final _Server server;
  final NetworkCancelSignal? cancel;
  late final ContinuedFetch fetch;
  // Cancelled by the cases that stop reading; the rest read to the end.
  // ignore: cancel_subscriptions
  late StreamSubscription<List<int>> subscription;
  final bytes = BytesBuilder(copy: false);
  var done = false;
  Object? error;

  List<int> get starts => [for (final r in server.requests) r.start];
  List<bool> get elsewhere => [for (final r in server.requests) r.elsewhere];

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
    expect(server.peakConnections, 1, reason: 'one connection at a time');
  }
}

void main() {
  for (final size in [1, _mib, 10 * _mib + _mib ~/ 2]) {
    test('streams $size bytes on one connection', () {
      fakeAsync((async) {
        final run = _Run(async, _Server(size));
        async.elapse(const Duration(seconds: 30));
        run.expectComplete();
        expect(run.server.requests, hasLength(1));
      });
    });
  }

  test('a stalled body continues from the received byte after 2 s; '
      'a second stall without a byte goes elsewhere', () {
    fakeAsync((async) {
      final server = _Server(2 * _mib)
        ..plan = (nth) => switch (nth) {
          0 => const _Plan(stallAt: 320 * 1024),
          1 => const _Plan(stallAt: 0),
          _ => _Plan.fast,
        };
      final run = _Run(async, server);
      // 320 KiB arrive in about 50 ms; 2 s later the body counts as stalled.
      async.elapse(const Duration(milliseconds: 1900));
      expect(run.starts, [0]);
      async.elapse(const Duration(seconds: 1));
      expect(run.starts, [0, 320 * 1024]);
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
      expect(run.starts, [0, 320 * 1024, 320 * 1024]);
      expect(run.elsewhere, [false, false, true]);
    });
  });

  test('a dropped connection continues on the same route', () {
    fakeAsync((async) {
      final server = _Server(2 * _mib)
        ..plan = (nth) =>
            nth == 0 ? const _Plan(failAt: 512 * 1024) : _Plan.fast;
      final run = _Run(async, server);
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
      expect(run.starts, [0, 512 * 1024]);
      expect(run.elsewhere, [false, false]);
    });
  });

  for (final (ending, last, ends) in [
    (
      'a failure',
      const _Plan(stallAt: 0, failAt: 0, interval: Duration(seconds: 15)),
      isA<_Reset>(),
    ),
    (
      'an early end',
      const _Plan(endAt: 0, interval: Duration(seconds: 15)),
      isA<NetworkFailureException>().having(
        (e) => e.kind,
        'kind',
        NetworkFailureKind.reset,
      ),
    ),
  ]) {
    test('continuations stop at the bound, then $ending ends it as a '
        'transport failure', () {
      fakeAsync((async) {
        final server = _Server(2 * _mib)
          ..plan = (nth) => switch (nth) {
            0 => const _Plan(stallAt: 64 * 1024),
            ContinuedFetch.defaultContinuations => last,
            _ => const _Plan(stallAt: 0),
          };
        final run = _Run(async, server);
        async.elapse(const Duration(seconds: 14));
        expect(
          run.server.requests,
          hasLength(1 + ContinuedFetch.defaultContinuations),
        );
        expect(run.error, isNull, reason: 'the last connection is left alone');
        // Its own idle timeout, played here by the server, ends it.
        async.elapse(const Duration(seconds: 15));
        expect(run.error, ends);
        expect(
          run.server.requests,
          hasLength(1 + ContinuedFetch.defaultContinuations),
        );
        expect(server.openConnections, 0);
      });
    });
  }

  test('every continuation asks If-Range with the first ETag', () {
    fakeAsync((async) {
      final server = _Server(2 * _mib, etag: '"abc"')
        ..plan = (nth) =>
            nth == 0 ? const _Plan(failAt: 64 * 1024) : _Plan.fast;
      final run = _Run(async, server);
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
      expect(
        server.requests.skip(1).map((r) => r.ifRange),
        everyElement('"abc"'),
      );
    });
  });

  for (final (name, plan, etag) in [
    ('a 200 to If-Range', const _Plan(status: 200), '"abc"'),
    ('a shifted range', const _Plan(shiftRange: 1), null),
  ]) {
    test('$name fails the transfer without appending or a retry', () {
      fakeAsync((async) {
        final server = _Server(2 * _mib, etag: etag)
          ..plan = (nth) => nth == 0 ? const _Plan(failAt: 64 * 1024) : plan;
        final run = _Run(async, server);
        async.elapse(const Duration(seconds: 30));
        expect(run.error, isA<ContinuedFetchMismatch>());
        expect(run.bytes.length, 64 * 1024);
        expect(server.requests, hasLength(2));
        expect(server.openConnections, 0);
      });
    });
  }

  test('a 200 to a continuation without If-Range is asked again elsewhere; '
      'each time, it fails the transfer', () {
    for (final always in [false, true]) {
      fakeAsync((async) {
        final server = _Server(2 * _mib)
          ..plan = (nth) => switch (nth) {
            0 => const _Plan(failAt: 64 * 1024),
            1 => const _Plan(status: 200),
            _ => always ? const _Plan(status: 200) : _Plan.fast,
          };
        final run = _Run(async, server);
        async.elapse(const Duration(seconds: 30));
        if (always) {
          expect(run.error, isA<ContinuedFetchMismatch>());
          expect(run.bytes.length, 64 * 1024);
          expect(
            server.requests,
            hasLength(1 + ContinuedFetch.defaultContinuations),
          );
        } else {
          run.expectComplete();
          expect(run.elsewhere, [false, false, true]);
        }
        expect(server.openConnections, 0);
      });
    }
  });

  test('cancelling closes the live connection', () {
    fakeAsync((async) {
      final server = _Server(10 * _mib)
        ..plan = (_) =>
            const _Plan(chunk: 1000, interval: Duration(milliseconds: 100));
      final cancel = _Cancel();
      final run = _Run(async, server, cancel: cancel);
      async.elapse(const Duration(seconds: 1));
      expect(server.openConnections, 1);
      cancel.cancel();
      async.flushMicrotasks();
      expect(run.error, isA<ContinuedFetchCancelled>());
      expect(server.openConnections, 0);
      expect(async.periodicTimerCount, 0);
    });
  });

  test('closing before anyone listens leaves nothing running', () {
    fakeAsync((async) {
      final server = _Server(4 * _mib);
      final fetch = ContinuedFetch(open: server.open);
      late Stream<List<int>> output;
      unawaited(
        server
            .open(0, cancel: _Cancel())
            .then((first) => output = fetch.continueFrom(first)),
      );
      async.flushMicrotasks();
      fetch.close();
      Object? error;
      var done = false;
      output.listen(
        null,
        onError: (Object e) => error = e,
        onDone: () => done = true,
      );
      async.elapse(const Duration(seconds: 10));
      expect(error, isA<ContinuedFetchCancelled>());
      expect(done, isTrue);
      expect(server.requests, hasLength(1));
      expect(server.openConnections, 0);
      expect(async.periodicTimerCount, 0);
    });
  });

  test('a paused reader is not a stall; resuming finishes', () {
    fakeAsync((async) {
      final server = _Server(2 * _mib);
      final run = _Run(async, server);
      run.subscription.pause();
      async.elapse(const Duration(seconds: 10));
      expect(server.requests, hasLength(1));
      run.subscription.resume();
      async.elapse(const Duration(seconds: 30));
      run.expectComplete();
    });
  });
}
