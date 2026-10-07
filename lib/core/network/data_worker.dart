/// Pure data work — JSON decoding, entity mapping, snapshot encoding — run
/// away from the UI isolate. See `frontend/state-management.md` (feed data
/// pipeline).
library;

import 'dart:async';
import 'dart:developer';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../debug/frame_probe.dart';

/// Runs a pure function on its input and hands back the result.
///
/// [task] and [input] may cross an isolate boundary: [task] must be a
/// top-level or static function (or a closure over sendable values only),
/// and the result must be sendable too. [label] names the work in traces.
abstract interface class DataWorker {
  Future<R> run<I, R>(
    R Function(I input) task,
    I input, {
    required String label,
  });

  /// Stops the worker; requests still running fail.
  Future<void> close();
}

/// Runs the work on the calling isolate, measured under its label. For
/// tests and tools; the app uses [IsolateDataWorker].
///
/// Inline work never crosses an isolate, so a task or result the app's
/// worker could not carry would still pass here. Debug builds send both to
/// a throwaway port first, which rejects them the same way.
class InlineDataWorker implements DataWorker {
  const InlineDataWorker();

  @override
  Future<R> run<I, R>(
    R Function(I input) task,
    I input, {
    required String label,
  }) => Future.sync(() {
    assert(_sendable(task));
    final result = FrameProbe.instance.measure(label, () => task(input));
    assert(_sendable(result));
    return result;
  });

  static bool _sendable(Object? value) {
    final port = RawReceivePort();
    try {
      port.sendPort.send(value);
    } finally {
      port.close();
    }
    return true;
  }

  @override
  Future<void> close() async {}
}

/// One long-lived background isolate for all data work, spawned on first
/// use. A short-lived isolate per response costs a spawn each time; this
/// one costs a message each way, and the result is copied on the worker's
/// side, not the UI isolate's.
///
/// If the isolate dies, every request in flight fails with a
/// [DataWorkerExited] and the next request spawns a fresh one.
class IsolateDataWorker implements DataWorker {
  IsolateDataWorker({this.debugName = 'data-worker'});

  final String debugName;

  Future<SendPort>? _port;
  Completer<SendPort>? _ready;
  Isolate? _isolate;
  RawReceivePort? _inbox;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;
  var _closed = false;

  @override
  Future<R> run<I, R>(
    R Function(I input) task,
    I input, {
    required String label,
  }) async {
    if (_closed) throw StateError('data worker is closed');
    final job = _job(task, input, label);
    final port = await (_port ??= _spawn());
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send((id, job));
    return await completer.future as R;
  }

  /// Built outside the async [run] so the closure captures only its
  /// arguments: one created inside an async body can capture the suspend
  /// state, which an isolate message cannot carry.
  static Object? Function() _job<I, R>(
    R Function(I input) task,
    I input,
    String label,
  ) =>
      () => Timeline.timeSync(label, () => task(input));

  Future<SendPort> _spawn() async {
    final ready = _ready = Completer<SendPort>();
    // Failed before anyone awaits it (closed or exited mid-spawn) is still
    // reported to the requests that do.
    ready.future.ignore();
    final inbox = _inbox = RawReceivePort();
    inbox.handler = (Object? message) {
      switch (message) {
        case final SendPort port:
          if (!ready.isCompleted) ready.complete(port);
        case (final int id, final Object? result):
          _pending.remove(id)?.complete(result);
        case (final int id, final Object error, final StackTrace? stack):
          _pending.remove(id)?.completeError(error, stack);
        case null:
          // onExit: the isolate is gone, whatever it was doing.
          _reset();
      }
    };
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        inbox.sendPort,
        onExit: inbox.sendPort,
        debugName: debugName,
      );
    } on Object {
      _reset();
      rethrow;
    }
    if (_closed) {
      // Closed while spawning: nothing may outlive close().
      isolate.kill(priority: Isolate.immediate);
    } else {
      _isolate = isolate;
    }
    return ready.future;
  }

  /// Drops the isolate and fails everything waiting on it; the next
  /// request spawns afresh.
  void _reset() {
    const error = DataWorkerExited();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    _ready = null;
    final pending = [..._pending.values];
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(error);
    }
    _inbox?.close();
    _inbox = null;
    _isolate = null;
    _port = null;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _reset();
  }
}

/// The data worker's isolate went away while work was outstanding.
class DataWorkerExited implements Exception {
  const DataWorkerExited();

  @override
  String toString() => 'DataWorkerExited: the data worker isolate exited';
}

void _workerMain(SendPort reply) {
  final inbox = RawReceivePort();
  inbox.handler = (Object? message) {
    final (int id, Object? Function() job) =
        message! as (int, Object? Function());
    try {
      reply.send((id, job()));
    } on Object catch (error, stack) {
      try {
        reply.send((id, error, stack));
      } on Object {
        // The error itself does not cross isolates; its text does.
        reply.send((id, RemoteError('$error', '$stack'), null));
      }
    }
  };
  reply.send(inbox.sendPort);
}

/// The app's data worker; tests that render the app may override it with
/// [InlineDataWorker].
final dataWorkerProvider = Provider<DataWorker>((ref) {
  final worker = IsolateDataWorker();
  ref.onDispose(() => unawaited(worker.close()));
  return worker;
});
