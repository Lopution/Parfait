import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../logging/crash_log.dart';
import '../network/compat/image_demand.dart';
import 'image_worker_host.dart';
import 'image_worker_protocol.dart';
import 'lane_permit_gate.dart';

/// Main-isolate handle to the background image worker.
///
/// Sends fetch/cancel/promote/config messages downstream and completes the
/// matching request futures when results come back. Request ids are
/// client-allocated; several requests for one URL coalesce inside the
/// worker, so [cancelUrl] drops every in-flight id of that URL.
///
/// Cancellation follows the same contract the legacy `ImageDemand`-gated
/// file service kept: the shared [ImageDemand] is the single truth for
/// "does anyone still want this URL", and its [ImageDemand.onMaybeUnwanted]
/// hook drives this client's cancels — a URL that drops out of every
/// window and holder set has its queued worker request dropped (after the
/// release grace, which the demand itself defines). An isolate that dies
/// mid-flight fails every pending request explicitly; there is no silent
/// fallback to the legacy chain.
class ImageWorkerClient implements ImageFetcher {
  ImageWorkerClient._(
    this._worker,
    this.demand,
    this._isolate,
    this._inbox,
    this._events,
  );

  /// The demand bookkeeping the call sites already use. This is the shared
  /// instance the legacy image cache consults — one truth for both
  /// pipelines during the staged migration.
  final ImageDemand demand;

  final SendPort _worker;
  final Isolate? _isolate;
  final ReceivePort _inbox;
  final StreamController<WorkerEvent> _events;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  final _pending = <int, (String url, Completer<FetchResult>)>{};
  final _idsByUrl = <String, Set<int>>{};
  final _rechecks = <String, Timer>{};
  final _statusRequests = <int, Completer<ImageWorkerStatus>>{};
  var _nextId = 1;
  Object? _dead;

  /// Wiring callbacks: the worker's learned routes are persisted by the
  /// main isolate's real stores, and an exhausted image host feeds the
  /// auto-source winner reset — the same contract
  /// `NetworkAccessPolicy.onImageHostExhausted` keeps for API traffic.
  void Function(String host, String address)? onFastRouteLearned;
  void Function(String identity, String group, String kind)? onRouteKindLearned;
  void Function(String host)? onRouteExhausted;

  /// Download progress of a URL [watchProgress] turned on.
  void Function(String url, int received, int? total)? onProgress;

  /// Called once when the worker dies (never on [dispose]).
  void Function(Object error)? onDied;

  /// Spawns the worker isolate and waits for its ready event. Throws
  /// synchronously (never silently) when init fails.
  static Future<ImageWorkerClient> start({
    required ImageWorkerConfig config,
    required String cacheDir,
    required ImageDemand demand,
    Duration readyTimeout = const Duration(seconds: 15),
    @visibleForTesting
    void Function(Map<String, Object?> args) entry = imageWorkerEntry,
  }) async {
    final inbox = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    // Uncaught errors stay fatal: the host catches at its message boundary,
    // so one that escapes is a broken worker, reported on errorPort and
    // then on exitPort.
    final errors = errorPort.listen((raw) {
      final [message, stack] = (raw as List).cast<String?>();
      CrashLog.record(RemoteError('$message', stack ?? ''));
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        entry,
        {
          'sendPort': inbox.sendPort,
          'config': config.toJson(),
          'cacheDir': cacheDir,
        },
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
      );
      return await _connect(
        inbox,
        demand,
        readyTimeout,
        worker: (isolate: isolate, exitPort: exitPort, errors: errors),
      );
    } on Object {
      isolate?.kill();
      inbox.close();
      exitPort.close();
      unawaited(errors.cancel());
      errorPort.close();
      rethrow;
    }
  }

  /// Test seam — attach to a worker (usually an in-process
  /// [ImageWorkerHost]) that reports its readiness on [inbox].
  static Future<ImageWorkerClient> attach(
    ReceivePort inbox, {
    required ImageDemand demand,
    Duration readyTimeout = const Duration(seconds: 15),
  }) {
    return _connect(inbox, demand, readyTimeout);
  }

  static Future<ImageWorkerClient> _connect(
    ReceivePort inbox,
    ImageDemand demand,
    Duration readyTimeout, {
    _SpawnedWorker? worker,
  }) async {
    // One subscription on the inbox multiplexes the ready handshake and the
    // event stream — a ReceivePort only ever accepts a single listener.
    // Events that arrive before the client subscribes are buffered by the
    // single-subscription controller.
    final events = StreamController<WorkerEvent>();
    final ready = Completer<SendPort>();
    void fail(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
    }

    final inboxSub = inbox.listen((raw) {
      final event = decodeWorkerEvent(raw);
      if (event is ReadyEvent && !ready.isCompleted) {
        ready.complete(event.sendPort);
      } else if (event is InitErrorEvent && !ready.isCompleted) {
        fail(ImageWorkerUnavailable('init failed: ${event.message}'));
      } else {
        events.add(event);
      }
    });
    // The exit port serves both phases: during the handshake an exit fails
    // the start at once instead of after the timeout; afterwards it kills
    // the client. Port messages are events, so none can land between the
    // ready resumption and the assignment below.
    ImageWorkerClient? client;
    final exitSub = worker?.exitPort.listen((_) {
      fail(const ImageWorkerUnavailable('exited during init'));
      client?._onExit();
    });
    SendPort workerPort;
    try {
      workerPort = await ready.future.timeout(readyTimeout);
    } on Object {
      unawaited(inboxSub.cancel());
      unawaited(exitSub?.cancel());
      unawaited(events.close());
      rethrow;
    }
    client = ImageWorkerClient._(
      workerPort,
      demand,
      worker?.isolate,
      inbox,
      events,
    );
    client._subscriptions
      ..add(events.stream.listen(client._onEvent))
      ..add(inboxSub);
    if (exitSub != null) client._subscriptions.add(exitSub);
    if (worker != null) client._subscriptions.add(worker.errors);
    demand.onMaybeUnwanted = client._onMaybeUnwanted;
    return client;
  }

  /// Fetches [url] through the worker: disk hit or a lane-admitted network
  /// fetch. The returned future completes with the committed [File], a
  /// [FetchFailure] for transport/HTTP failures, or [ImageFetchDropped]
  /// when this URL is cancelled before it streams; [ImageWorkerUnavailable]
  /// once the worker is dead.
  @override
  Future<FetchResult> fetch(
    String url, {
    required ImageFetchPriority priority,
  }) {
    final dead = _dead;
    if (dead != null) return Future.error(dead);
    final id = _nextId++;
    final completer = Completer<FetchResult>();
    _pending[id] = (url, completer);
    (_idsByUrl[url] ??= {}).add(id);
    _worker.send(encodeFetch(FetchRequest(id, url, priority)));
    return completer.future;
  }

  /// Cancels every in-flight request for [url]; their futures complete
  /// with [ImageFetchDropped] — the same signal preload already maps to
  /// "nobody wanted this in time".
  void cancelUrl(String url) {
    final ids = _idsByUrl.remove(url);
    if (ids == null) return;
    for (final id in ids) {
      _pending.remove(id)?.$2.completeError(ImageFetchDropped(url));
      _worker.send(encodeCancel(id));
    }
  }

  /// Foreground-promotes the queued fetch for [url] — the demand layer's
  /// on-screen signal, mirroring `PriorityFileService.promote`. Only a URL
  /// with a request in flight can have a queued fetch, so a widget's first
  /// hold costs no message.
  void promoteUrl(String url) {
    if (_idsByUrl.containsKey(url)) _worker.send(encodePromote(url));
  }

  /// Starts or stops progress reports for [url]. The caller counts its
  /// watchers; this only forwards the switch.
  void watchProgress(String url, {required bool watching}) {
    if (_dead == null) _worker.send(encodeWatch(url, watching: watching));
  }

  /// The worker's queue and disk usage right now.
  Future<ImageWorkerStatus> status() {
    final dead = _dead;
    if (dead != null) return Future.error(dead);
    final id = _nextId++;
    final completer = Completer<ImageWorkerStatus>();
    _statusRequests[id] = completer;
    _worker.send(encodeStatusRequest(id));
    return completer.future;
  }

  /// Pushes a new config snapshot (mirror, DoH, ECH, mode, identity) into
  /// the worker — the same rebuild the provider layer performs on the
  /// main-side policy.
  void applyConfig(ImageWorkerConfig config) =>
      _worker.send(encodeConfig(config));

  /// The demand hook: [url] may have become unwanted. A window eviction
  /// counts at once (windows carry no release grace); a release gets its
  /// [releaseGrace] re-check, mirroring the legacy admit-time `wants`
  /// evaluation. A URL with nothing in flight has nothing to cancel — most
  /// releases, since an image on screen has usually loaded.
  void _onMaybeUnwanted(String url) {
    if (!_idsByUrl.containsKey(url)) return;
    if (!demand.wants(url)) {
      cancelUrl(url);
      return;
    }
    _rechecks[url] ??= Timer(releaseGrace, () {
      _rechecks.remove(url);
      if (!demand.wants(url)) cancelUrl(url);
    });
  }

  void _onEvent(WorkerEvent event) {
    switch (event) {
      case ResultEvent(:final id, :final path, :final bytes):
        _complete(
          id,
          (entry) => entry.$2.complete(FetchResult(id, File(path), bytes)),
        );
      case ProgressEvent(:final url, :final received, :final total):
        onProgress?.call(url, received, total);
      case FailureEvent(:final id, :final message, :final statusCode):
        _complete(
          id,
          (entry) => entry.$2.completeError(
            FetchFailure(id, message, statusCode: statusCode),
          ),
        );
      case FastRouteLearnedEvent(:final host, :final address):
        onFastRouteLearned?.call(host, address);
      case RouteKindLearnedEvent(
        :final networkIdentity,
        :final group,
        :final kind,
      ):
        onRouteKindLearned?.call(networkIdentity, group, kind);
      case RouteExhaustedEvent(:final host):
        onRouteExhausted?.call(host);
      case WorkerErrorEvent(:final message, :final stack):
        CrashLog.record(RemoteError(message, stack));
      case StatusEvent(:final id, :final status):
        _statusRequests.remove(id)?.complete(status);
      case ReadyEvent():
        break; // consumed during connect
      case InitErrorEvent():
        _die(ImageWorkerUnavailable('init failed: ${event.message}'));
    }
  }

  void _complete(int id, void Function((String, Completer<FetchResult>)) run) {
    final entry = _pending.remove(id);
    if (entry == null) return;
    final ids = _idsByUrl[entry.$1];
    ids?.remove(id);
    if (ids != null && ids.isEmpty) _idsByUrl.remove(entry.$1);
    run(entry);
  }

  void _onExit() {
    _die(const ImageWorkerUnavailable('isolate exited'));
  }

  /// The isolate died. Every pending and later request fails explicitly
  /// and the death is logged; a dead worker is a loud error, not a
  /// fallback. [onDied] lets the owner start a replacement.
  void _die(Object error) {
    if (_dead != null) return;
    _dead = error;
    CrashLog.record(error);
    _cancelRechecks();
    _failPending(error);
    onDied?.call(error);
  }

  void _failPending(Object error) {
    for (final entry in _pending.values) {
      entry.$2.completeError(error);
    }
    _pending.clear();
    _idsByUrl.clear();
    for (final completer in _statusRequests.values) {
      completer.completeError(error);
    }
    _statusRequests.clear();
  }

  /// Whether the worker died or this client was disposed; [fetch] then
  /// fails at once.
  bool get isDead => _dead != null;

  /// Test probe: in-flight request ids.
  @visibleForTesting
  int get pendingCount => _pending.length;

  void _cancelRechecks() {
    for (final timer in _rechecks.values) {
      timer.cancel();
    }
    _rechecks.clear();
  }

  /// Stops the worker at once: pending requests fail with
  /// [ImageWorkerUnavailable], and the isolate and its ports are gone
  /// before the returned future, which only waits for the listeners to
  /// detach.
  Future<void> dispose() async {
    _dead ??= const ImageWorkerUnavailable('disposed');
    _cancelRechecks();
    _failPending(_dead!);
    if (identical(demand.onMaybeUnwanted, _onMaybeUnwanted)) {
      demand.onMaybeUnwanted = null;
    }
    _isolate?.kill();
    _inbox.close();
    final cancels = [for (final s in _subscriptions) s.cancel()];
    unawaited(_events.close());
    await Future.wait(cancels);
  }
}

typedef _SpawnedWorker = ({
  Isolate isolate,
  ReceivePort exitPort,
  StreamSubscription<Object?> errors,
});
