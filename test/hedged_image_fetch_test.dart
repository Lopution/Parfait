import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parfait/core/image/hedged_image_fetch.dart';
import 'package:parfait/core/image/image_fetch_scheduler.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/segmented_fetch.dart';

/// One send at the network boundary, answered by the case.
class _Send {
  _Send(this.track, Future<void> abort, {required this.hedge}) {
    unawaited(abort.then((_) => _abort()));
  }

  final ImageRouteTrack track;
  final bool hedge;
  final _headers = Completer<http.StreamedResponse>();
  late final _body = StreamController<List<int>>(
    onCancel: () => cancelled = true,
  );
  var aborted = false;
  var cancelled = false;

  Future<http.StreamedResponse> get response => _headers.future;

  void answer({int status = 200, int? length = 4}) => _headers.complete(
    http.StreamedResponse(_body.stream, status, contentLength: length),
  );

  void fail(Object error) => _headers.completeError(error);

  void send(List<int> bytes) => _body.add(bytes);

  void finish() => unawaited(_body.close());

  /// Like rhttp: no headers yet fails the send, a body fails its stream.
  void _abort() {
    aborted = true;
    final error = http.RequestAbortedException(Uri.parse('https://i/a.jpg'));
    if (!_headers.isCompleted) {
      _headers.completeError(error);
    } else if (!_body.isClosed) {
      _body.addError(error);
      unawaited(_body.close());
    }
  }
}

/// The worker's hedged fetches behind the real scheduler, in fake time.
class _Worker {
  _Worker(this.async, {int hedges = ImageStall.hedges})
    : budget = SegmentBudget(limit: hedges) {
    scheduler = ImageFetchScheduler<List<int>>(
      execute: (url, flight) {
        final mine = <_Send>[];
        sends[url] = mine;
        return HedgedImageFetch<List<int>>(
          flight: flight,
          budget: budget,
          send: (track, abort, {required hedge}) {
            // The ladder notes the route it chose.
            track.sent.add(hedge ? 'other' : 'first');
            final send = _Send(track, abort, hedge: hedge);
            mine.add(send);
            return send.response;
          },
          statusError: (statusCode) => StateError('HTTP $statusCode'),
          store: (body, length) async {
            final bytes = BytesBuilder();
            await for (final chunk in body) {
              bytes.add(chunk);
              // Written to disk: the reader pauses meanwhile.
              await Future<void>.value();
            }
            final stored = bytes.takeBytes();
            this.stored.add(stored);
            return stored;
          },
          progress: (received, total) => progress.add((received, total)),
          timer: Timer.new,
        ).run();
      },
    );
  }

  final FakeAsync async;
  final SegmentBudget budget;
  late final ImageFetchScheduler<List<int>> scheduler;
  final sends = <String, List<_Send>>{};
  final stored = <List<int>>[];
  final progress = <(int, int?)>[];

  _Result fetch(
    String url, {
    int id = 1,
    ImageFetchPriority priority = ImageFetchPriority.foreground,
  }) {
    final result = _Result(scheduler.submit(id, url, priority: priority));
    async.flushMicrotasks();
    return result;
  }

  void elapse(int milliseconds) =>
      async.elapse(Duration(milliseconds: milliseconds));
}

class _Result {
  _Result(Future<List<int>> future) {
    unawaited(future.then((v) => value = v, onError: (Object e) => error = e));
  }

  List<int>? value;
  Object? error;
}

void main() {
  test('a send stalled after its first bytes is sent again elsewhere at '
      '2 s; the second whole body is stored once', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      final result = worker.fetch('a');
      final first = worker.sends['a']!.single
        ..answer()
        ..send([1, 2]);
      worker.elapse(1900);
      expect(worker.sends['a'], hasLength(1));

      worker.elapse(200);
      final hedge = worker.sends['a']!.last;
      expect(hedge.hedge, isTrue);
      expect(hedge.track.avoid, {'first'});
      hedge
        ..answer()
        ..send([1, 2, 3, 4])
        ..finish();
      async.flushMicrotasks();
      expect(result.value, [1, 2, 3, 4]);
      expect(worker.stored, [
        [1, 2, 3, 4],
      ]);
      expect((first.aborted, first.cancelled), (true, true));
      expect(worker.budget.inUse, 0);
    });
  });

  test('the first send finishing stops the hedge', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      final result = worker.fetch('a');
      final first = worker.sends['a']!.single
        ..answer()
        ..send([1, 2]);
      worker.elapse(2100);
      final hedge = worker.sends['a']!.last
        ..answer()
        ..send([1]);

      first
        ..send([3, 4])
        ..finish();
      async.flushMicrotasks();
      expect(result.value, [1, 2, 3, 4]);
      expect(worker.stored, hasLength(1));
      expect((hedge.aborted, hedge.cancelled), (true, true));
      expect(worker.budget.inUse, 0);
    });
  });

  for (final (name, headersAt, hedged) in [
    ('headers at 2.4 s are in time', 2400, false),
    ('no headers after 2.5 s send it again', 2500, true),
  ]) {
    test(name, () {
      fakeAsync((async) {
        final worker = _Worker(async);
        final result = worker.fetch('a');
        worker.elapse(headersAt);
        worker.sends['a']!.first
          ..answer()
          ..send([1, 2, 3, 4])
          ..finish();
        async.flushMicrotasks();
        expect(result.value, [1, 2, 3, 4]);
        expect(worker.sends['a'], hasLength(hedged ? 2 : 1));
      });
    });
  }

  test('a fourth image stalled at once is not sent again', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      for (final (i, url) in ['a', 'b', 'c', 'd'].indexed) {
        worker.fetch(url, id: i);
        worker.sends[url]!.single.answer();
      }
      worker.elapse(2100);
      expect(
        [
          for (final url in ['a', 'b', 'c', 'd']) worker.sends[url]!.length,
        ],
        [2, 2, 2, 1],
      );
    });
  });

  test('a prefetch is sent again only once a visible request joins it', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      worker.fetch('a', priority: ImageFetchPriority.background);
      worker.sends['a']!.single.answer();
      worker.elapse(5000);
      expect(worker.sends['a'], hasLength(1));

      worker.fetch('a', id: 2);
      expect(worker.sends['a'], hasLength(2));
    });
  });

  for (final (name, outcome) in <(String, void Function(_Send hedge))>[
    ('finds no other route', (hedge) => hedge.fail(const NoOtherImageRoute())),
    ('answers 503', (hedge) => hedge.answer(status: 503)),
    (
      'would hold too much',
      (hedge) => hedge.answer(length: ImageStall.hedgeBytes + 1),
    ),
  ]) {
    test('a hedge that $name ends alone', () {
      fakeAsync((async) {
        final worker = _Worker(async);
        final result = worker.fetch('a');
        final first = worker.sends['a']!.single
          ..answer()
          ..send([1, 2]);
        worker.elapse(2100);
        outcome(worker.sends['a']!.last);
        async.flushMicrotasks();
        expect(worker.budget.inUse, 0);

        first
          ..send([3, 4])
          ..finish();
        async.flushMicrotasks();
        expect(result.value, [1, 2, 3, 4]);
      });
    });
  }

  test('both sends failing fail with the first one\'s error', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      final result = worker.fetch('a');
      final first = worker.sends['a']!.single..answer(status: 404);
      worker.elapse(2600);
      // The first answer is still being read when the hedge goes out.
      expect(worker.sends['a'], hasLength(2));
      worker.sends['a']!.last.fail(StateError('reset'));
      first.finish();
      async.flushMicrotasks();
      expect('${result.error}', 'Bad state: HTTP 404');
    });
  });

  test('progress follows the further of the two sends', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      worker.fetch('a');
      worker.sends['a']!.single
        ..answer()
        ..send([1]);
      worker.elapse(2100);
      worker.sends['a']!.last
        ..answer()
        ..send([1])
        ..send([2, 3]);
      async.flushMicrotasks();
      expect(worker.progress, [(1, 4), (3, 4)]);
    });
  });

  test('a stalled image nobody wants is given up', () {
    fakeAsync((async) {
      final worker = _Worker(async);
      final result = worker.fetch('a');
      final first = worker.sends['a']!.single
        ..answer()
        ..send([1]);
      worker.scheduler.cancel(1);
      async.flushMicrotasks();
      expect(result.error, isA<ImageFetchDropped>());
      expect(first.aborted, isFalse);

      worker.elapse(2100);
      expect(first.aborted, isTrue);
      expect(worker.sends['a'], hasLength(1));
      expect(worker.scheduler.inFlight, 0);
    });
  });
}
