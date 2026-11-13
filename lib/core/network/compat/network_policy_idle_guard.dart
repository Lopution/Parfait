part of 'network_policy.dart';

/// Adds the two streaming budgets a route's connect timeout cannot express.
/// Image-purpose routes deliberately carry no *total* request timeout (a
/// large download must not abort mid-body — see
/// [RhttpClientFactory.timeoutsFor]), which left two unbounded waits:
/// `send()` (connect+TLS+request+first byte) and each gap between body
/// chunks. A socket that stalls at either point previously hung the
/// request forever; the route ladder never got a chance to advance.
///
/// A headers deadline miss surfaces from `send()` as a `timeout`, so the
/// ladder can advance for idempotent GETs. A body stall surfaces on the
/// stream as a `TimeoutException`: the image cache shows a visible error
/// and the download manager retries through its resume anchor. Either
/// way, and whenever a reader gives the body up, the request's abort
/// trigger fires: rhttp keeps the transfer and its socket otherwise.
///
/// A request given up, by its reader or by its own abort trigger, counts
/// against its route candidate when it had stalled ([ImageStall]): no
/// headers for [headersStall], or no body bytes for [bodyStall].
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

  /// Hears how bodies end on a pixiv image route candidate.
  final _CandidateObserver? _observer;

  /// Time budget for `send()` to resolve, i.e. until response headers.
  final Duration headersTimeout;

  /// Maximum gap between body chunks before the stream errors out.
  final Duration idleTimeout;

  final Duration headersStall;
  final Duration bodyStall;

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
    _rearm();
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
  late final StreamSubscription<List<int>> _source;
  void Function(List<int> event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  Timer? _timer;

  void _data(List<int> event) {
    _rearm();
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
      _timer?.cancel();
      unawaited(_cancelSource());
    } else {
      // The body goes on after the error; so does its idle budget.
      _rearm();
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
    _timer?.cancel();
    _end(_BodyEnd.done);
    _onDone?.call();
  }

  void _rearm() {
    _timer?.cancel();
    // The idle budget is wall-clock semantics, so the timer is rooted in
    // the real zone: a fake-zone timer (widget tests) would stay pending
    // for any stream still draining at teardown, and in production there
    // is no fake zone anyway.
    _timer = Zone.root.createTimer(_idle, () {
      _end(_BodyEnd.failed);
      unawaited(_cancelSource());
      _error(
        TimeoutException('response stream idle', _idle),
        StackTrace.current,
      );
    });
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
    _timer?.cancel();
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
