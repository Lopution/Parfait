import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'network_contracts.dart';

/// Extra connections shared by every segmented transfer (image originals
/// and downloads). A transfer's first connection is not counted here: its
/// image lane or download slot already accounts for it.
class SegmentBudget {
  SegmentBudget({this.limit = defaultLimit});

  /// With 8 foreground + 2 background image slots and 3 download jobs this
  /// stays under ~19 HTTP/1.1 connections per host. Lower it if the CDN
  /// starts answering 403/429 under load.
  static const defaultLimit = 6;

  final int limit;
  var _inUse = 0;

  @visibleForTesting
  int get inUse => _inUse;

  bool tryAcquire() {
    if (_inUse >= limit) return false;
    _inUse++;
    return true;
  }

  void release() {
    assert(_inUse > 0, 'SegmentBudget released more than acquired');
    _inUse--;
  }
}

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

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;

  /// Tears the connection down. Safe to call twice and after [body] was
  /// listened to.
  final Future<void> Function() close;

  ContentRange? get contentRange => parseContentRange(headers['content-range']);
}

/// Opens bytes [start]..[endInclusive] on a new connection. [ifRange] is the
/// first response's ETag: a changed file then answers 200, not 206.
typedef RangeOpen =
    Future<RangeResponse> Function(
      int start,
      int endInclusive, {
      String? ifRange,
      required NetworkCancelSignal cancel,
    });

/// A segment answered with something other than its own bytes of the same
/// file. Never retried: stitching it in would produce a mixed file.
class SegmentedFetchMismatch implements Exception {
  const SegmentedFetchMismatch(this.message);

  final String message;

  @override
  String toString() => 'SegmentedFetchMismatch: $message';
}

/// The transfer was cancelled through its signal before it finished.
class SegmentedFetchCancelled implements Exception {
  const SegmentedFetchCancelled();

  @override
  String toString() => 'SegmentedFetchCancelled';
}

/// Fetches the rest of a file in parallel byte ranges and returns it as one
/// in-order stream.
///
/// The caller opens the first range itself (so it can fall back to a plain
/// response when the server ignores `Range`) and hands the 206 to
/// [continueFrom]. That connection reads the first segment and then keeps
/// claiming segments; up to [maxParallel] − 1 more connections come from
/// [budget] and are skipped when none is free.
///
/// A segment that streams far slower than the others, or not at all, is
/// restarted on a new connection from the byte it reached — at most
/// [maxRestarts] times; after that it is left alone and the transport's own
/// idle timeout is the last resort. Workers never run more than
/// [maxParallel] segments ahead of the delivered bytes, so at most that many
/// segments sit in memory.
///
/// One instance serves one transfer.
class SegmentedFetch {
  SegmentedFetch({
    required RangeOpen open,
    required SegmentBudget budget,
    this.segmentBytes = defaultSegmentBytes,
    this.maxParallel = defaultParallel,
    DateTime Function()? clock,
  }) : assert(segmentBytes > 0),
       assert(maxParallel > 0),
       _open = open,
       _budget = budget,
       _clock = clock ?? DateTime.now;

  static const defaultSegmentBytes = 1 << 20;
  static const defaultParallel = 4;
  static const maxRestarts = 2;

  static const _tick = Duration(seconds: 1);

  /// How long a connection runs before its speed is judged, and the window
  /// that speed is measured over.
  static const _speedWindow = Duration(seconds: 3);

  /// Slow means under the median pace divided by this.
  static const _slowFactor = 3;

  /// Finished segments that still count towards the median pace.
  static const _recentFinished = 8;

  /// A nearly finished segment is not worth a new connection.
  static const _minRestartRemaining = 256 * 1024;
  static const _stallAfter = Duration(seconds: 5);

  final RangeOpen _open;
  final SegmentBudget _budget;
  final DateTime Function() _clock;
  final int segmentBytes;
  final int maxParallel;

  late final StreamController<List<int>> _output;
  final _segments = <_Segment>[];
  late final int _total;
  String? _etag;
  RangeResponse? _first;

  /// Index of the segment whose bytes are delivered next.
  var _next = 0;
  var _fetched = 0;

  /// Average speeds of recently finished segments. A segment lagging at
  /// the head blocks the window, so the others finish and go idle; their
  /// pace is still the yardstick.
  final _finishedSpeeds = ListQueue<double>();
  var _workers = 0;
  var _waiting = 0;
  var _closed = false;
  Completer<void>? _windowMoved;
  Timer? _ticker;
  var _started = false;

  /// Bytes received so far, delivered or still buffered.
  int get fetchedBytes => _fetched;

  /// Streams the bytes from [first]'s start to the end of the file. [first]
  /// must be a 206 whose `Content-Range` carries the total size.
  Stream<List<int>> continueFrom(
    RangeResponse first, {
    NetworkCancelSignal? cancel,
  }) {
    assert(!_started, 'SegmentedFetch serves one transfer');
    _started = true;
    final range = first.contentRange;
    if (first.statusCode != 206 || range == null || range.total == null) {
      throw ArgumentError.value(first.statusCode, 'first', 'not a sized 206');
    }
    final total = range.total!;
    _total = total;
    _etag = first.headers['etag'];
    _first = first;
    _segments.add(_Segment(range.start, range.end + 1));
    for (var start = range.end + 1; start < total; start += segmentBytes) {
      final end = start + segmentBytes;
      _segments.add(_Segment(start, end < total ? end : total));
    }
    _output = StreamController<List<int>>(
      onListen: _start,
      onResume: _deliver,
      onCancel: _shutdown,
    );
    cancel?.whenCancel.then((_) => close());
    return _output.stream;
  }

  /// Ends the transfer early: every connection closes and the output ends
  /// with [SegmentedFetchCancelled]. Safe to call twice and before the
  /// output is listened to.
  void close() {
    if (!_started || _closed) return;
    _output
      ..addError(const SegmentedFetchCancelled())
      ..close();
    _shutdown();
  }

  void _start() {
    // Closed before anyone listened.
    if (_closed) return;
    _ticker = Timer.periodic(_tick, (_) => _check());
    final first = _segments.first..claimed = true;
    _workers++;
    unawaited(_work(first, _first, extra: false));
    _first = null;
    _spawn();
  }

  /// Adds connections while segments are left unclaimed and the budget
  /// allows. A new worker claims synchronously, so the loop sees it.
  void _spawn() {
    while (!_closed &&
        _workers < maxParallel &&
        _unclaimed > _waiting &&
        _budget.tryAcquire()) {
      _workers++;
      unawaited(_work(null, null, extra: true));
    }
  }

  int get _unclaimed => _segments.where((s) => !s.claimed).length;

  Future<void> _work(
    _Segment? segment,
    RangeResponse? response, {
    required bool extra,
  }) async {
    try {
      while (!_closed) {
        segment ??= await _claim();
        if (segment == null) return;
        await _fetch(segment, response);
        segment = null;
        response = null;
        _spawn();
      }
    } on Object catch (error, stack) {
      _fail(error, stack);
    } finally {
      _workers--;
      if (extra) _budget.release();
    }
  }

  /// The lowest unclaimed segment, waiting while it lies past the window.
  /// Null when every segment is claimed or the transfer ended.
  Future<_Segment?> _claim() async {
    while (!_closed) {
      final index = _segments.indexWhere((s) => !s.claimed);
      if (index < 0) return null;
      if (index < _next + maxParallel) return _segments[index]..claimed = true;
      _waiting++;
      try {
        await (_windowMoved ??= Completer<void>()).future;
      } finally {
        _waiting--;
      }
    }
    return null;
  }

  Future<void> _fetch(_Segment segment, RangeResponse? opened) async {
    var response = opened;
    while (!_closed) {
      final attempt = _Attempt(_clock(), segment.received);
      segment.attempt = attempt;
      try {
        if (response == null) {
          final from = segment.start + segment.received;
          final to = segment.end - 1;
          response = await _open(
            from,
            to,
            ifRange: _etag,
            cancel: attempt.cancel,
          );
          attempt.response = response;
          if (attempt.restartRequested || _closed) throw const _Restart();
          _validate(response, from, to);
        } else {
          attempt.response = response;
        }
        await _read(segment, attempt, response);
        if (segment.received < segment.length) {
          throw StateError(
            'segment ${segment.start} ended at '
            '${segment.received}/${segment.length} bytes',
          );
        }
        segment
          ..attempt = null
          ..complete = true;
        final pace = attempt.averageSpeed(_clock(), segment.received);
        if (pace != null) _finishedSpeeds.add(pace);
        if (_finishedSpeeds.length > _recentFinished) {
          _finishedSpeeds.removeFirst();
        }
        _deliver();
        return;
      } on SegmentedFetchMismatch {
        rethrow;
      } on Object {
        segment.attempt = null;
        response = null;
        await attempt.abort();
        if (_closed) return;
        // A requested restart was already counted.
        if (attempt.restartRequested) continue;
        if (segment.restarts >= maxRestarts) rethrow;
        segment.restarts++;
      }
    }
  }

  void _validate(RangeResponse response, int from, int to) {
    final range = response.contentRange;
    if (response.statusCode != 206 ||
        range == null ||
        range.start != from ||
        range.end != to ||
        range.total != _total) {
      throw SegmentedFetchMismatch(
        'asked $from-$to/$_total, got ${response.statusCode} '
        '${response.headers['content-range']}',
      );
    }
  }

  Future<void> _read(_Segment segment, _Attempt attempt, RangeResponse r) {
    final done = Completer<void>();
    attempt.reading = done;
    attempt.subscription = r.body.listen(
      (chunk) {
        if (attempt.restartRequested || _closed || done.isCompleted) return;
        if (segment.received + chunk.length > segment.length) {
          done.completeError(
            SegmentedFetchMismatch(
              'segment ${segment.start} sent more than ${segment.length} '
              'bytes',
            ),
          );
          return;
        }
        segment.pending.add(chunk);
        segment.received += chunk.length;
        _fetched += chunk.length;
        attempt.lastByteAt = _clock();
        _deliver();
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Hands the in-order prefix to the output while it is not paused.
  void _deliver() {
    if (_closed) return;
    while (_next < _segments.length) {
      if (_output.isPaused) return;
      final segment = _segments[_next];
      if (segment.pending.isNotEmpty) _output.add(segment.pending.takeBytes());
      if (!segment.complete) return;
      _next++;
      _windowMoved?.complete();
      _windowMoved = null;
    }
    unawaited(_output.close());
    _shutdown();
  }

  /// Restarts stalled and slow segments; see the class comment.
  void _check() {
    if (_closed) return;
    final now = _clock();
    final active = [
      for (final s in _segments)
        if (s.attempt != null) s,
    ];
    final speeds = <_Segment, double>{};
    for (final s in active) {
      final attempt = s.attempt!;
      attempt.sample(now, s.received);
      // Only connections already streaming set the pace.
      if (attempt.subscription != null) speeds[s] = attempt.speed;
    }
    for (final s in active) {
      final attempt = s.attempt!;
      if (s.restarts >= maxRestarts || attempt.restartRequested) continue;
      if (now.difference(attempt.lastByteAt) >= _stallAfter ||
          _isSlow(s, now, speeds)) {
        s.restarts++;
        unawaited(attempt.restart());
      }
    }
  }

  bool _isSlow(_Segment s, DateTime now, Map<_Segment, double> speeds) {
    final own = speeds[s];
    if (own == null ||
        now.difference(s.attempt!.startedAt) < _speedWindow ||
        s.length - s.received <= _minRestartRemaining) {
      return false;
    }
    final others = [
      for (final entry in speeds.entries)
        if (entry.key != s) entry.value,
      ..._finishedSpeeds,
    ];
    if (others.isEmpty) return false;
    others.sort();
    final mid = others.length ~/ 2;
    final median = others.length.isOdd
        ? others[mid]
        : (others[mid - 1] + others[mid]) / 2;
    return own < median / _slowFactor;
  }

  void _fail(Object error, StackTrace stack) {
    if (_closed) return;
    _output
      ..addError(error, stack)
      ..close();
    _shutdown();
  }

  /// Closes every connection; buffered bytes are dropped.
  void _shutdown() {
    if (_closed) return;
    _closed = true;
    _ticker?.cancel();
    _windowMoved?.complete();
    _windowMoved = null;
    for (final segment in _segments) {
      final attempt = segment.attempt;
      segment.attempt = null;
      if (attempt != null) unawaited(attempt.abort());
    }
    final first = _first;
    _first = null;
    if (first != null) unawaited(first.close().catchError((_) {}));
  }
}

class _Segment {
  _Segment(this.start, this.end);

  final int start;

  /// Exclusive.
  final int end;
  int get length => end - start;

  var received = 0;

  /// Received but not yet delivered.
  final pending = BytesBuilder(copy: false);
  var claimed = false;
  var complete = false;
  var restarts = 0;
  _Attempt? attempt;
}

class _Restart implements Exception {
  const _Restart();
}

class _SegmentCancel implements NetworkCancelSignal {
  final _completer = Completer<void>();

  @override
  bool get isCancelled => _completer.isCompleted;

  @override
  Future<void> get whenCancel => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// One connection's try at a segment.
class _Attempt {
  _Attempt(this.startedAt, this.startReceived) : lastByteAt = startedAt {
    _samples.add((startedAt, startReceived));
  }

  /// The segment's byte count when this connection started.
  final int startReceived;

  final DateTime startedAt;
  DateTime lastByteAt;
  final cancel = _SegmentCancel();
  RangeResponse? response;
  StreamSubscription<List<int>>? subscription;
  Completer<void>? reading;
  var restartRequested = false;
  final _samples = ListQueue<(DateTime, int)>();

  /// Bytes per second over the last speed window.
  double get speed {
    final (fromTime, fromBytes) = _samples.first;
    final (toTime, toBytes) = _samples.last;
    final seconds = toTime.difference(fromTime).inMicroseconds / 1e6;
    return seconds <= 0 ? 0 : (toBytes - fromBytes) / seconds;
  }

  /// Bytes per second since this connection started; null before any time
  /// has passed.
  double? averageSpeed(DateTime now, int received) {
    final seconds = now.difference(startedAt).inMicroseconds / 1e6;
    return seconds <= 0 ? null : (received - startReceived) / seconds;
  }

  /// Records [received] at [now], keeping one sample at or before the start
  /// of the speed window as the baseline.
  void sample(DateTime now, int received) {
    _samples.add((now, received));
    final windowStart = now.subtract(SegmentedFetch._speedWindow);
    while (_samples.length > 2 &&
        !_samples.elementAt(1).$1.isAfter(windowStart)) {
      _samples.removeFirst();
    }
  }

  Future<void> restart() {
    restartRequested = true;
    final done = reading;
    if (done != null && !done.isCompleted) done.completeError(const _Restart());
    return abort();
  }

  /// Cancels the request and closes the connection.
  Future<void> abort() async {
    cancel.cancel();
    final done = reading;
    if (done != null && !done.isCompleted) done.completeError(const _Restart());
    // Cancelling takes effect at once; its future may only settle on a later
    // turn of the root zone, which nothing here needs to wait for. A body
    // torn down mid-transfer may complete it with an error: the connection
    // is gone either way.
    subscription?.cancel().ignore();
    try {
      await response?.close();
    } on Object {
      // A connection torn down mid-transfer may complain; it is gone either
      // way.
    }
  }
}
