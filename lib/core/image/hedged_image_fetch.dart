import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../network/compat/network_contracts.dart';
import '../network/compat/segmented_fetch.dart' show SegmentBudget;
import 'image_fetch_scheduler.dart' show ImageFlight;

/// Sends the GET once on [track], aborted when [abort] completes. A [hedge]
/// is the second send.
typedef HedgeSend =
    Future<http.StreamedResponse> Function(
      ImageRouteTrack track,
      Future<void> abort, {
      required bool hedge,
    });

/// One whole-body image GET (not an original) that, when its route stalls
/// while someone looks at the image, is sent once more over another route;
/// the first whole body is kept. See [ImageStall].
///
/// The first send streams into [store] as any fetch does. It stalls with
/// no headers for [ImageStall.headers], or no body bytes for
/// [ImageStall.body]; the flight hears it ([ImageFlight.stalled]). A
/// stalled flight a foreground request waits on, now or once one joins,
/// sends a hedge to a candidate the first send did not use, while
/// [budget] has room. The hedge's body is held in memory: the first send's
/// partial file goes when the hedge wins, the hedge goes when the first
/// send finishes. One that fails while the other runs just ends; when both
/// fail, the first send's error is the fetch's.
class HedgedImageFetch<T> {
  HedgedImageFetch({
    required ImageFlight flight,
    required SegmentBudget budget,
    required HedgeSend send,
    required Object Function(int statusCode) statusError,
    required Future<T> Function(Stream<List<int>> body, int? length) store,
    void Function(int received, int? total)? progress,
    Timer Function(Duration duration, void Function() callback)? timer,
  }) : _flight = flight,
       _budget = budget,
       _send = send,
       _statusError = statusError,
       _store = store,
       _progress = progress,
       _timer = timer ?? _rootTimer;

  final ImageFlight _flight;
  final SegmentBudget _budget;
  final HedgeSend _send;
  final Object Function(int statusCode) _statusError;
  final Future<T> Function(Stream<List<int>> body, int? length) _store;
  final void Function(int received, int? total)? _progress;
  final Timer Function(Duration, void Function()) _timer;

  late final _primary = _Leg(_flight);
  _Leg? _hedge;
  _Leg? _winner;
  late final Future<T?> _primaryRun;
  final _result = Completer<T>();
  Timer? _quiet;
  var _stalled = false;
  var _received = 0;
  int? _total;

  /// Like the policy's idle guard, the stall clock runs in the root zone:
  /// a fake-zone timer (widget tests) would stay pending for any transfer
  /// still in flight at teardown.
  static Timer _rootTimer(Duration duration, void Function() callback) {
    final zone = Zone.current;
    return Zone.root.createTimer(duration, () => zone.run(callback));
  }

  /// Runs the fetch; call once.
  Future<T> run() {
    _flight.onSeen = _hedgeIfStalled;
    _rearm(ImageStall.headers);
    _primaryRun = _runPrimary();
    return _result.future.whenComplete(() {
      _quiet?.cancel();
      _flight.onSeen = null;
    });
  }

  Future<T?> _runPrimary() async {
    final leg = _primary;
    try {
      final response = await _send(leg.track, leg.abort, hedge: false);
      if (_winner != null) {
        _discard(response);
        return null;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw _statusError(response.statusCode);
      }
      final length = response.contentLength;
      _total ??= length;
      _rearm(ImageStall.body);
      final body = _EndableBody(response.stream);
      leg.end = body.end;
      // `map` holds an error that `end` adds while the store is paused
      // writing, which a reader of the raw body could not take then.
      final result = await _store(
        body.map((chunk) {
          _chunk(leg, chunk.length);
          return chunk;
        }),
        length,
      );
      leg.done = true;
      if (_claim(leg)) {
        _hedge?.stop();
        _result.complete(result);
      }
      return result;
    } on Object catch (error, stack) {
      leg.failure = (error, stack);
      _ended(leg);
      return null;
    }
  }

  Future<void> _runHedge(_Leg leg) async {
    try {
      final response = await _send(leg.track, leg.abort, hedge: true);
      if (_winner != null) {
        _discard(response);
        return;
      }
      final length = response.contentLength;
      if (response.statusCode != 200) {
        _discard(response);
        throw _statusError(response.statusCode);
      }
      if (length != null && length > ImageStall.hedgeBytes) {
        _discard(response);
        throw const _HedgeTooLarge();
      }
      _total ??= length;
      final bytes = await _collect(leg, response.stream);
      leg.done = true;
      if (!_claim(leg)) return;
      // The first send's partial file goes; its route hears that it was
      // given up stalled.
      _primary.stop();
      final T result;
      try {
        result =
            await _primaryRun ??
            await _store(Stream.value(bytes), length ?? bytes.length);
      } on Object catch (error, stack) {
        _result.completeError(error, stack);
        return;
      }
      _result.complete(result);
    } on Object catch (error, stack) {
      leg.failure = (error, stack);
      _ended(leg);
    } finally {
      _budget.release();
    }
  }

  /// [body] in memory, up to [ImageStall.hedgeBytes].
  Future<Uint8List> _collect(_Leg leg, Stream<List<int>> body) {
    final bytes = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    late final StreamSubscription<List<int>> subscription;
    void end(Object error) {
      if (done.isCompleted) return;
      done.completeError(error);
      subscription.cancel().ignore();
    }

    subscription = body.listen(
      (chunk) {
        if (done.isCompleted) return;
        bytes.add(chunk);
        if (bytes.length > ImageStall.hedgeBytes) {
          end(const _HedgeTooLarge());
          return;
        }
        _chunk(leg, chunk.length);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    leg.end = end;
    return done.future;
  }

  void _chunk(_Leg leg, int length) {
    leg.received += length;
    _rearm(ImageStall.body);
    if (leg.received > _received) {
      _received = leg.received;
      _progress?.call(_received, _total);
    }
  }

  void _rearm(Duration gap) {
    _quiet?.cancel();
    if (_winner != null) return;
    if (_stalled) {
      _stalled = false;
      _flight.stalled(false);
    }
    _quiet = _timer(gap, _onQuiet);
  }

  void _onQuiet() {
    if (_winner != null || _result.isCompleted) return;
    _stalled = true;
    _flight.stalled(true);
    _hedgeIfStalled();
  }

  void _hedgeIfStalled() {
    if (!_stalled ||
        _winner != null ||
        _result.isCompleted ||
        _hedge != null ||
        _flight.isCancelled ||
        !_flight.seen ||
        // A mirror, or no route yet: nothing to send it away from.
        _primary.track.sent.isEmpty ||
        !_budget.tryAcquire()) {
      return;
    }
    final leg = _hedge = _Leg(
      _flight,
      ImageRouteTrack(avoid: {..._primary.track.sent}),
    );
    unawaited(_runHedge(leg));
  }

  /// Whether [leg] is the first to finish.
  bool _claim(_Leg leg) {
    if (_winner != null) return false;
    _winner = leg;
    _quiet?.cancel();
    return true;
  }

  /// [leg] failed: the fetch fails with the first send's error once
  /// neither send can finish.
  void _ended(_Leg leg) {
    if (_winner != null || _result.isCompleted) return;
    final other = identical(leg, _primary) ? _hedge : _primary;
    if (other != null && !other.over) return;
    final (error, stack) = _primary.failure!;
    _result.completeError(error, stack);
  }

  static void _discard(http.StreamedResponse response) =>
      response.stream.listen(null).cancel().ignore();
}

/// One send of a [HedgedImageFetch].
class _Leg {
  _Leg(NetworkCancelSignal flight, [ImageRouteTrack? track])
    : track = track ?? ImageRouteTrack() {
    abort = Future.any([flight.whenCancel, _stopped.future]);
  }

  final ImageRouteTrack track;
  final _stopped = Completer<void>();

  /// The request's abort trigger: the flight stopped, or so did this send.
  late final Future<void> abort;
  var received = 0;
  var done = false;
  (Object, StackTrace)? failure;

  /// Ends the body for its reader with an error, once it is read.
  void Function(Object error)? end;

  bool get over => done || failure != null;

  /// The other send finished first.
  void stop() {
    if (!_stopped.isCompleted) _stopped.complete();
    end?.call(const _Superseded());
  }
}

/// A send's body given up because the other send finished first.
class _Superseded implements Exception {
  const _Superseded();
}

class _HedgeTooLarge implements Exception {
  const _HedgeTooLarge();
}

/// [_source] until [end] ends it with an error for its reader. Forwards the
/// source subscription, without a controller, like the policy's idle
/// guard.
class _EndableBody extends Stream<List<int>> {
  _EndableBody(this._source);

  final Stream<List<int>> _source;

  /// Ends the listener's subscription.
  void Function(Object error)? _endListened;
  Object? _endedEarly;

  void end(Object error) {
    final endListened = _endListened;
    if (endListened == null) {
      _endedEarly ??= error;
    } else {
      endListened(error);
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _EndableSubscription(
      _source,
      onData: onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError ?? false,
    );
    _endListened = subscription.end;
    if (_endedEarly case final error?) subscription.end(error);
    return subscription;
  }
}

class _EndableSubscription implements StreamSubscription<List<int>> {
  _EndableSubscription(
    Stream<List<int>> source, {
    required void Function(List<int> event)? onData,
    required Function? onError,
    required void Function()? onDone,
    required bool cancelOnError,
  }) : _onData = onData,
       _onError = onError,
       _onDone = onDone,
       _cancelOnError = cancelOnError {
    _source = source.listen(_data, onError: _sourceError, onDone: _done);
  }

  final Zone _zone = Zone.current;
  final bool _cancelOnError;
  late final StreamSubscription<List<int>> _source;
  void Function(List<int> event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  var _ended = false;
  var _cancelled = false;

  void _data(List<int> event) {
    if (!_ended) _onData?.call(event);
  }

  void _sourceError(Object error, StackTrace stack) {
    if (_ended) return;
    if (_cancelOnError) {
      _ended = true;
      _source.cancel().ignore();
    }
    _error(error, stack);
  }

  void _done() {
    if (_ended) return;
    _ended = true;
    _onDone?.call();
  }

  void end(Object error) {
    if (_ended) return;
    _ended = true;
    _source.cancel().ignore();
    _error(error, StackTrace.current);
    if (!_cancelled) _onDone?.call();
  }

  void _error(Object error, StackTrace stack) {
    final handler = _onError;
    if (handler is void Function(Object, StackTrace)) {
      handler(error, stack);
    } else if (handler is void Function(Object)) {
      handler(error);
    } else {
      _zone.handleUncaughtError(error, stack);
    }
  }

  /// Completes at once, as the idle guard's cancel does: a `map` hands an
  /// error on only after the cancel it starts.
  @override
  Future<void> cancel() {
    _cancelled = true;
    if (!_ended) {
      _ended = true;
      _source.cancel().ignore();
    }
    return Future<void>.value();
  }

  @override
  void onData(void Function(List<int> data)? handleData) =>
      _onData = handleData;

  @override
  void onError(Function? handleError) => _onError = handleError;

  @override
  void onDone(void Function()? handleDone) => _onDone = handleDone;

  @override
  void pause([Future<void>? resumeSignal]) => _source.pause(resumeSignal);

  @override
  void resume() => _source.resume();

  @override
  bool get isPaused => _source.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final result = Completer<E>();
    _onDone = () => result.complete(futureValue as E);
    _onError = (Object error, StackTrace stack) {
      cancel().ignore();
      result.completeError(error, stack);
    };
    return result.future;
  }
}
