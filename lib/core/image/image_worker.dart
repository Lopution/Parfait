import 'dart:async';

import '../logging/crash_log.dart';
import '../network/compat/image_demand.dart';
import 'image_worker_client.dart';
import 'image_worker_protocol.dart';
import 'lane_permit_gate.dart';

/// Starts a worker client for [config] that cancels through [demand].
typedef ImageWorkerStarter =
    Future<ImageWorkerClient> Function(
      ImageWorkerConfig config,
      ImageDemand demand,
    );

/// The app's image worker: one isolate behind a handle that lives as long
/// as the app.
///
/// Image widgets need a provider synchronously while the spawn is async, so
/// the isolate starts on the first request and requests wait for it. A
/// worker that dies is replaced on the next request, up to [maxStarts]
/// starts per session; past that every request fails with
/// [ImageWorkerUnavailable]. Every death and failed start lands in the
/// crash log — a replacement restarts the same pipeline, it never falls
/// back to the legacy one.
class ImageWorker implements ImageFetcher {
  ImageWorker({
    required ImageWorkerStarter start,
    required Future<ImageWorkerConfig> Function() config,
    this.maxStarts = defaultMaxStarts,
  }) : _start = start,
       _config = config {
    demand.onHeld = (url) => _live?.promoteUrl(url);
  }

  static const defaultMaxStarts = 3;

  final ImageWorkerStarter _start;
  final Future<ImageWorkerConfig> Function() _config;
  final int maxStarts;

  /// Holders and prefetch windows of the images this worker loads. It
  /// drives cancels and promotions and outlives any one isolate, so a
  /// replacement inherits it.
  final demand = ImageDemand();

  /// Forwarded from whichever worker is running; see [ImageWorkerClient].
  void Function(String host, String address)? onFastRouteLearned;
  void Function(String identity, String group, String kind)? onRouteKindLearned;
  void Function(String host)? onRouteExhausted;

  Future<ImageWorkerClient>? _client;
  ImageWorkerClient? _live;
  var _starts = 0;
  Object? _lastFailure;
  var _disposed = false;

  /// Isolates started this session, the first one included.
  int get starts => _starts;

  /// The running worker; null while starting or after it died.
  ImageWorkerClient? get live => _live;

  ImageWorkerState get state {
    if (_disposed) return ImageWorkerState.disposed;
    if (_live != null) return ImageWorkerState.running;
    if (_client != null) return ImageWorkerState.starting;
    if (_starts >= maxStarts) return ImageWorkerState.gaveUp;
    return _starts == 0 ? ImageWorkerState.idle : ImageWorkerState.stopped;
  }

  /// What the probe page shows. Never starts a worker; a running one that
  /// does not answer within [statusTimeout] reports that as its failure.
  Future<ImageWorkerSnapshot> snapshot() async {
    final client = _live;
    ImageWorkerStatus? status;
    Object? statusFailure;
    if (client != null) {
      try {
        status = await client.status().timeout(statusTimeout);
      } on Object catch (error) {
        statusFailure = error;
      }
    }
    return ImageWorkerSnapshot(
      state: state,
      starts: _starts,
      maxStarts: maxStarts,
      lastFailure: statusFailure ?? _lastFailure,
      status: status,
    );
  }

  static const statusTimeout = Duration(seconds: 2);

  @override
  Future<FetchResult> fetch(
    String url, {
    required ImageFetchPriority priority,
  }) async {
    final client = await _ready();
    return client.fetch(url, priority: priority);
  }

  /// Sends the current settings to the running worker. A worker that
  /// starts later reads them itself.
  Future<void> configChanged() async {
    final client = _live;
    if (client == null) return;
    final config = await _config();
    if (identical(client, _live)) client.applyConfig(config);
  }

  Future<ImageWorkerClient> _ready() {
    if (_disposed) {
      return Future.error(const ImageWorkerUnavailable('disposed'));
    }
    final current = _client;
    if (current != null) return current;
    if (_starts >= maxStarts) {
      return Future.error(
        ImageWorkerUnavailable('gave up after $_starts starts: $_lastFailure'),
      );
    }
    _starts++;
    return _client = _launch();
  }

  Future<ImageWorkerClient> _launch() async {
    final ImageWorkerClient client;
    try {
      client = await _start(await _config(), demand);
    } on Object catch (error, stack) {
      _lastFailure = error;
      _client = null;
      CrashLog.record(error, stack);
      throw error is ImageWorkerUnavailable
          ? error
          : ImageWorkerUnavailable('start failed: $error');
    }
    if (_disposed) {
      await client.dispose();
      throw const ImageWorkerUnavailable('disposed');
    }
    client
      ..onFastRouteLearned = onFastRouteLearned
      ..onRouteKindLearned = onRouteKindLearned
      ..onRouteExhausted = onRouteExhausted
      ..onDied = (error) {
        _lastFailure = error;
        if (!identical(_live, client)) return;
        _live = null;
        _client = null;
      };
    _live = client;
    return client;
  }

  Future<void> dispose() async {
    _disposed = true;
    final live = _live;
    _client = null;
    _live = null;
    // A start still in flight disposes its own client when it lands.
    await live?.dispose();
  }
}

enum ImageWorkerState {
  /// No request has needed it yet.
  idle,
  starting,
  running,

  /// It died; the next request starts a replacement.
  stopped,

  /// Every start this session is spent; requests fail.
  gaveUp,
  disposed,
}

/// The worker's state with its queue and disk usage when running.
class ImageWorkerSnapshot {
  const ImageWorkerSnapshot({
    required this.state,
    required this.starts,
    required this.maxStarts,
    this.lastFailure,
    this.status,
  });

  final ImageWorkerState state;
  final int starts;
  final int maxStarts;
  final Object? lastFailure;
  final ImageWorkerStatus? status;

  /// Plain-text lines for the probe page and its copied report.
  String describe() {
    final lines = ['image worker: ${state.name}, starts $starts/$maxStarts'];
    if (status case final status?) {
      lines
        ..add('  in flight ${status.inFlight}, queued ${status.queued}')
        ..add(
          '  disk ${status.diskEntries} files, '
          '${_megabytes(status.diskBytes)} / '
          '${_megabytes(status.diskMaxBytes)} MB',
        );
    }
    if (lastFailure case final failure?) lines.add('  last failure: $failure');
    return '${lines.join('\n')}\n';
  }

  static String _megabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);
}
