import 'dart:async';

import 'package:http/http.dart' as http;

import 'network_contracts.dart';

/// `Content-Range: bytes <start>-<end>/<total>`; [total] is null for `*`.
typedef ContentRange = ({int start, int end, int? total});

final _contentRangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$');

ContentRange? parseContentRange(String? value) {
  final match = _contentRangePattern.firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final total = match.group(3)!;
  return (
    start: int.parse(match.group(1)!),
    end: int.parse(match.group(2)!),
    total: total == '*' ? null : int.parse(total),
  );
}

/// One ranged response. Header names are lowercase.
class RangeResponse {
  RangeResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.close,
  });

  /// [response] as a range; closing it cancels an unread body, which
  /// still holds the connection.
  factory RangeResponse.fromHttp(http.StreamedResponse response) =>
      RangeResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.stream,
        close: () async {
          try {
            await response.stream.listen(null).cancel();
          } on StateError {
            // Already listened to: its subscriber tears it down.
          }
        },
      );

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;

  /// Tears the connection down. Safe to call twice and after [body] was
  /// listened to.
  final Future<void> Function() close;

  ContentRange? get contentRange => parseContentRange(headers['content-range']);
}

/// Opens the file from byte [start] to its end on a new connection.
/// [ifRange] is the first response's ETag: a changed file then answers 200,
/// not 206. A continuation goes [elsewhere] when another route may serve it
/// ([ImageRoutePin.awayFrom]).
typedef ContinuationOpen =
    Future<RangeResponse> Function(
      int start, {
      String? ifRange,
      required NetworkCancelSignal cancel,
      required bool elsewhere,
    });

/// A continuation answered with something other than the rest of the same
/// file. Never retried: appending it would produce a mixed file.
class ContinuedFetchMismatch implements Exception {
  const ContinuedFetchMismatch(this.message);

  final String message;

  @override
  String toString() => 'ContinuedFetchMismatch: $message';
}

/// The transfer was cancelled through its signal before it finished.
class ContinuedFetchCancelled implements Exception {
  const ContinuedFetchCancelled();

  @override
  String toString() => 'ContinuedFetchCancelled';
}

/// Fetches the rest of a file on one connection at a time, continuing from
/// the last received byte when that connection stops.
///
/// The caller opens the first request itself (so it can fall back to a
/// plain response when the server ignores `Range`) and hands the sized 206
/// to [continueFrom]. When no body bytes arrive for [stallAfter] (no
/// headers for [ImageStall.headers] on a continuation still opening), or
/// the connection fails or ends early, it is closed and the next asks
/// `bytes=<received>-`. A continuation stays on the transfer's route unless
/// the one before it also stopped before sending a byte, or a route ignored
/// `Range` for this file: then it goes elsewhere.
///
/// A continuation is appended only when it is a 206 from the asked byte with
/// the first response's total; anything else fails the transfer with
/// [ContinuedFetchMismatch]. A 200 to a continuation asked without
/// `If-Range` (the first response had no ETag, as with pximg) is that
/// route ignoring `Range`, not another file: it is closed and continued
/// elsewhere instead. After [maxContinuations] the live connection is left
/// alone: the transport's idle timeout is the last resort, and the next
/// failure ends the transfer.
///
/// One instance serves one transfer.
class ContinuedFetch {
  ContinuedFetch({
    required ContinuationOpen open,
    this.stallAfter = ImageStall.body,
    this.maxContinuations = defaultContinuations,
    DateTime Function()? clock,
  }) : assert(maxContinuations >= 0),
       _open = open,
       _clock = clock ?? DateTime.now;

  /// Room for a move to another route and a few retries there before the
  /// transport's idle timeout takes over.
  static const defaultContinuations = 4;

  static const _tick = Duration(milliseconds: 500);

  final ContinuationOpen _open;
  final DateTime Function() _clock;
  final Duration stallAfter;
  final int maxContinuations;

  late final StreamController<List<int>> _output;
  late final int _from;
  late final int _length;
  String? _etag;
  RangeResponse? _first;
  _Connection? _live;
  var _received = 0;
  var _continuations = 0;

  /// The next continuation avoids the route: it ignored `Range`.
  var _awayNext = false;
  var _paused = false;
  var _closed = false;
  var _started = false;
  Timer? _ticker;

  /// Streams the bytes from [first]'s start to the end of the file. [first]
  /// must be a 206 whose `Content-Range` carries the total size.
  Stream<List<int>> continueFrom(
    RangeResponse first, {
    NetworkCancelSignal? cancel,
  }) {
    assert(!_started, 'ContinuedFetch serves one transfer');
    _started = true;
    final range = first.contentRange;
    if (first.statusCode != 206 || range == null || range.total == null) {
      throw ArgumentError.value(first.statusCode, 'first', 'not a sized 206');
    }
    _from = range.start;
    _length = range.total! - range.start;
    _etag = first.headers['etag'];
    _first = first;
    _output = StreamController<List<int>>(
      onListen: _start,
      onPause: _pause,
      onResume: _resume,
      onCancel: _shutdown,
    );
    unawaited(cancel?.whenCancel.then((_) => close()));
    return _output.stream;
  }

  /// Ends the transfer early: the connection closes and the output ends
  /// with [ContinuedFetchCancelled]. Safe to call twice and before the
  /// output is listened to.
  void close() {
    if (!_started || _closed) return;
    _output.addError(const ContinuedFetchCancelled());
    unawaited(_output.close());
    _shutdown();
  }

  void _start() {
    // Closed before anyone listened.
    if (_closed) return;
    _ticker = Timer.periodic(_tick, (_) => _check());
    final connection = _live = _Connection(_clock());
    _attach(connection, _first!);
    _first = null;
  }

  void _attach(_Connection connection, RangeResponse response) {
    connection.response = response;
    connection.lastByteAt = _clock();
    connection.subscription = response.body.listen(
      (chunk) {
        if (connection != _live || _closed) return;
        if (_received + chunk.length > _length) {
          _fail(
            ContinuedFetchMismatch(
              'sent more than the $_length bytes from $_from',
            ),
          );
          return;
        }
        _received += chunk.length;
        connection
          ..received += chunk.length
          ..lastByteAt = _clock();
        _output.add(chunk);
      },
      onError: (Object error, StackTrace stack) {
        if (connection == _live) _continueAfter(error, stack);
      },
      onDone: () {
        if (connection != _live || _closed) return;
        if (_received == _length) {
          unawaited(_output.close());
          _shutdown();
        } else {
          _continueAfter(
            StateError('connection ended at ${_from + _received}'),
          );
        }
      },
      cancelOnError: true,
    );
    if (_paused) connection.subscription!.pause();
  }

  /// Opens the next connection, or ends the transfer with [error] once the
  /// continuations are spent.
  void _continueAfter(Object error, [StackTrace? stack]) {
    if (_closed) return;
    if (_continuations >= maxContinuations) {
      _fail(
        error is _WholeFile ? ContinuedFetchMismatch(error.message) : error,
        stack,
      );
      return;
    }
    final previous = _live!;
    final elsewhere =
        _awayNext || (_continuations > 0 && previous.received == 0);
    _awayNext = false;
    _continuations++;
    unawaited(previous.abort());
    final connection = _live = _Connection(_clock());
    final start = _from + _received;
    unawaited(
      _open(
        start,
        ifRange: _etag,
        cancel: connection.cancel,
        elsewhere: elsewhere,
      ).then(
        (response) {
          if (connection != _live || _closed) {
            unawaited(_closeQuietly(response));
            return;
          }
          connection.response = response;
          if (response.statusCode == 200 && _etag == null) {
            _awayNext = true;
            _continueAfter(
              _WholeFile('asked bytes=$start-, got the whole file'),
            );
            return;
          }
          final range = response.contentRange;
          if (response.statusCode != 206 ||
              range == null ||
              range.start != start ||
              range.total != _from + _length) {
            _fail(
              ContinuedFetchMismatch(
                'asked bytes=$start-/${_from + _length}, got '
                '${response.statusCode} ${response.headers['content-range']}',
              ),
            );
            return;
          }
          _attach(connection, response);
        },
        onError: (Object error, StackTrace stack) {
          if (connection == _live) _continueAfter(error, stack);
        },
      ),
    );
  }

  /// Continues a connection that stopped sending; see the class comment.
  void _check() {
    if (_closed || _paused || _continuations >= maxContinuations) return;
    final connection = _live;
    if (connection == null) return;
    final limit = connection.subscription == null
        ? ImageStall.headers
        : stallAfter;
    if (_clock().difference(connection.lastByteAt) >= limit) {
      _continueAfter(const _Stalled());
    }
  }

  void _pause() {
    _paused = true;
    _live?.subscription?.pause();
  }

  /// A reader that paused is not a stalled connection: its wait does not
  /// count.
  void _resume() {
    _paused = false;
    final connection = _live;
    if (connection == null) return;
    connection.lastByteAt = _clock();
    connection.subscription?.resume();
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _output.addError(error, stack);
    unawaited(_output.close());
    _shutdown();
  }

  /// Closes the connection.
  void _shutdown() {
    if (_closed) return;
    _closed = true;
    _ticker?.cancel();
    final live = _live;
    _live = null;
    if (live != null) unawaited(live.abort());
    final first = _first;
    _first = null;
    if (first != null) unawaited(_closeQuietly(first));
  }
}

Future<void> _closeQuietly(RangeResponse response) async {
  try {
    await response.close();
  } on Object {
    // A connection torn down mid-transfer may complain; it is gone either
    // way.
  }
}

class _Stalled implements Exception {
  const _Stalled();

  @override
  String toString() => 'ContinuedFetch: the connection stalled';
}

/// A continuation asked without `If-Range` was answered with the whole
/// file.
class _WholeFile implements Exception {
  const _WholeFile(this.message);

  final String message;

  @override
  String toString() => 'ContinuedFetch: $message';
}

class _ConnectionCancel implements NetworkCancelSignal {
  final _completer = Completer<void>();

  @override
  bool get isCancelled => _completer.isCompleted;

  @override
  Future<void> get whenCancel => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// One connection of the transfer.
class _Connection {
  _Connection(this.lastByteAt);

  /// When it last sent a byte, opened, or its reader resumed.
  DateTime lastByteAt;
  final cancel = _ConnectionCancel();
  RangeResponse? response;
  StreamSubscription<List<int>>? subscription;

  /// Body bytes it delivered.
  var received = 0;

  /// Cancels the request and closes the connection.
  Future<void> abort() async {
    cancel.cancel();
    // Cancelling takes effect at once; its future may only settle on a later
    // turn of the root zone, which nothing here needs to wait for (NET-16).
    subscription?.cancel().ignore();
    final response = this.response;
    if (response != null) await _closeQuietly(response);
  }
}
