part of 'network_policy.dart';

/// Adds headers and body-idle budgets to streaming image/download routes
/// (which carry no total timeout so large transfers never abort mid-body).
/// An aborted or stalled request fires the abort trigger and reports to
/// [_observer] when it had stalled ([ImageStall]).
class _StreamIdleGuardClient extends http.BaseClient {
  _StreamIdleGuardClient(
    this._inner, {
    this.headersTimeout = defaultHeadersTimeout,
    this.idleTimeout = defaultIdleTimeout,
    this.headersStall = ImageStall.headers,
    this.bodyStall = ImageStall.body,
    _CandidateObserver? observer,
  }) : _observer = observer;

  final http.Client _inner;
  final _CandidateObserver? _observer;
  final Duration headersTimeout;
  final Duration idleTimeout;
  final Duration headersStall;
  final Duration bodyStall;

  void rebindRevision(NetworkRevision revision) =>
      _observer?.rebindRevision(revision);

  static const defaultHeadersTimeout = Duration(seconds: 15);
  static const defaultIdleTimeout = Duration(seconds: 15);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // rhttp's transfer, and its socket, outlive a dropped body or a
    // timed-out send until the server sends again; aborting the request
    // ends them, so a lane freed by a timeout never leaves one behind.
    final abandoned = Completer<void>();
    void abandon() {
      if (!abandoned.isCompleted) abandoned.complete();
    }

    final trigger = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    var givenUp = false;
    unawaited(trigger?.then((_) => givenUp = true, onError: (_) {}));
    final sent = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _inner
          .send(_abortable(request, abandoned.future))
          .timeout(headersTimeout);
    } on TimeoutException {
      abandon();
      rethrow;
    } on Object {
      if (givenUp && sent.elapsed >= headersStall) _observer?.failed();
      rethrow;
    }
    return http.StreamedResponse(
      http.ByteStream(
        _IdleGuardStream(
          response.stream,
          idleTimeout,
          stall: bodyStall,
          givenUp: trigger,
          onAbandon: abandon,
          onEnd: _bodyEnd(request, response, sent),
        ),
      ),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();

  /// Tells the observer what [response] shows of its route: a `Range`
  /// answered or ignored, a server error, or (through the returned
  /// callback) how a 2xx body ends. Other answers say nothing of the
  /// route.
  void Function(_BodyEnd end, int bytes)? _bodyEnd(
    http.BaseRequest request,
    http.StreamedResponse response,
    Stopwatch sent,
  ) {
    final observer = _observer;
    if (observer == null) return null;
    final status = response.statusCode;
    if (request.headers.containsKey('range') &&
        (status == 200 || status == 206)) {
      observer.answeredRange(served: status == 206);
    }
    if (status >= 500) {
      observer.failed();
      return null;
    }
    if (status < 200 || status >= 300) {
      observer.abandoned();
      return null;
    }
    final headers = sent.elapsed;
    return (end, bytes) => switch (end) {
      _BodyEnd.done => observer.loaded(
        headers: headers,
        total: sent.elapsed,
        bytes: bytes,
      ),
      _BodyEnd.failed => observer.failed(),
      _BodyEnd.abandoned => observer.abandoned(),
    };
  }

  /// [request] whose abort trigger also fires on [abandoned]. Image and
  /// download exits send plain [http.Request]s; any other shape goes out
  /// as it is.
  static http.BaseRequest _abortable(
    http.BaseRequest request,
    Future<void> abandoned,
  ) {
    if (request is! http.Request) return request;
    final trigger = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    return http.AbortableRequest(
        request.method,
        request.url,
        abortTrigger: trigger == null
            ? abandoned
            : Future.any([trigger, abandoned]),
      )
      ..headers.addAll(request.headers)
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..bodyBytes = request.bodyBytes;
  }
}

/// Per-chunk idle deadline for a response body. Implemented as a `Stream`
/// subclass that forwards the source subscription directly — deliberately
/// NOT `Stream.timeout` or a `StreamController` pass-through, because
/// controller-based wrappers never deliver under `testWidgets`' FakeAsync
/// event loop (they would silently stall every image load in widget
/// tests). Forwarding `listen` keeps the source's own delivery path, so
/// data/done flow through one synchronous hop with no extra buffering.
///
/// On an idle gap the listener's error handler gets a `TimeoutException`
/// and the source subscription is cancelled, releasing the socket. A body
/// its reader cancels, or whose request is aborted ([givenUp]), ends
/// failed when it had brought nothing for [stall], else abandoned.
class _IdleGuardStream extends Stream<List<int>> {
  _IdleGuardStream(
    this._source,
    this.idle, {
    required this.stall,
    required this.givenUp,
    required this.onAbandon,
    this.onEnd,
  });

  final Stream<List<int>> _source;
  final Duration idle;
  final Duration stall;
  final Future<void>? givenUp;

  /// Aborts the request once its body is given up.
  final void Function() onAbandon;

  /// Told once how the body ended, and how many bytes it brought.
  final void Function(_BodyEnd end, int bytes)? onEnd;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _IdleGuardSubscription(
    _source,
    idle,
    stall: stall,
    givenUp: givenUp,
    onAbandon: onAbandon,
    onEnd: onEnd,
    onData: onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError ?? false,
  );
}

/// Holds the handlers itself, so the ones set after `listen` — `asFuture`
/// (behind `drain`) or `onError` — still see the idle timeout. Forwarding them to the source subscription left `drain()` on a
/// stalled body waiting forever.
class _IdleGuardSubscription implements StreamSubscription<List<int>> {
  _IdleGuardSubscription(
    Stream<List<int>> source,
    this._idle, {
    required Duration stall,
    required Future<void>? givenUp,
    required void Function() onAbandon,
    required void Function(_BodyEnd end, int bytes)? onEnd,
    required void Function(List<int> event)? onData,
    required Function? onError,
    required void Function()? onDone,
    required bool cancelOnError,
  }) : _onAbandon = onAbandon,
       _onEnd = onEnd,
       _onData = onData,
       _onError = onError,
       _onDone = onDone,
       _cancelOnError = cancelOnError,
       _stall = stall {
    _source = source.listen(_data, onError: _sourceError, onDone: _done);
    _armTimer(_idle);
    // Before the abort's own error, which would read as the route's.
    unawaited(givenUp?.then((_) => _end(_givenUp), onError: (_) {}));
  }

  /// The listener's zone: the idle timer runs in the root zone.
  final Zone _zone = Zone.current;
  final Duration _idle;
  final void Function() _onAbandon;
  final void Function(_BodyEnd end, int bytes)? _onEnd;
  final bool _cancelOnError;
  final Duration _stall;

  /// Since the headers or the last chunk.
  final _quiet = Stopwatch()..start();
  var _bytes = 0;
  var _ended = false;
  var _closed = false;
  late final StreamSubscription<List<int>> _source;
  void Function(List<int> event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  Timer? _timer;

  void _data(List<int> event) {
    _quiet.reset();
    _bytes += event.length;
    _onData?.call(event);
  }

  _BodyEnd get _givenUp =>
      _quiet.elapsed >= _stall ? _BodyEnd.failed : _BodyEnd.abandoned;

  void _end(_BodyEnd end) {
    if (_ended) return;
    _ended = true;
    _onEnd?.call(end, _bytes);
  }

  void _sourceError(Object error, StackTrace stack) {
    _end(_BodyEnd.failed);
    if (_cancelOnError) {
      _closed = true;
      _timer?.cancel();
      _timer = null;
      unawaited(_cancelSource());
    } else {
      // The body goes on after the error; so does its idle budget.
      _quiet.reset();
      if (_timer == null) _armTimer(_idle);
    }
    _error(error, stack);
  }

  /// Like any subscription, an error without a handler is the zone's.
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

  void _done() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _end(_BodyEnd.done);
    _onDone?.call();
  }

  void _armTimer(Duration delay) {
    _timer?.cancel();
    // The idle budget is wall-clock semantics, so the timer is rooted in
    // the real zone: a fake-zone timer (widget tests) would stay pending
    // for any stream still draining at teardown, and in production there
    // is no fake zone anyway.
    _timer = Zone.root.createTimer(delay, _onIdleTick);
  }

  void _onIdleTick() {
    _timer = null;
    if (_closed) return;
    final remaining = _idle - _quiet.elapsed;
    if (remaining > Duration.zero) {
      _armTimer(remaining);
      return;
    }
    _closed = true;
    _end(_BodyEnd.failed);
    unawaited(_cancelSource());
    _error(TimeoutException('response stream idle', _idle), StackTrace.current);
  }

  /// Also stops the idle timer: an abandoned body (raced loser drained
  /// late, caller gone) would otherwise leak a pending timer until it fires.
  ///
  /// Completes at once rather than with the source's cancel, which on rhttp
  /// waits for Rust's next event: a `.map` under `await for` hands an error
  /// on only after the cancel it started ends, so the idle timeout reached
  /// the image cache 15–30 s late.
  @override
  Future<void> cancel() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _end(_givenUp);
    unawaited(_cancelSource());
    return Future<void>.value();
  }

  /// rhttp's body is flutter_rust_bridge's `async*` stream: cancelled while
  /// it waits for Rust, it goes on waiting, and a body error Rust reports
  /// next fails the cancel future instead of reaching any handler. The
  /// listener gave the body up, so that error is dropped; unhandled, it
  /// ended the image worker isolate. The request's abort ends the transfer
  /// on the Rust side.
  Future<void> _cancelSource() {
    _onAbandon();
    return _source.cancel().catchError((Object _) {});
  }

  @override
  void onData(void Function(List<int> event)? handleData) =>
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
      unawaited(cancel());
      result.completeError(error, stack);
    };
    return result.future;
  }
}

enum _BodyEnd { done, failed, abandoned }
