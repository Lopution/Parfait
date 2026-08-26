import 'dart:async';

import '../network/pixiv_client_identity.dart';
import 'download_request.dart';
import 'download_sink.dart';
import 'download_task.dart';
import 'download_transport.dart';
import 'pixiv_download_transport.dart';

/// Per-task progress snapshot emission interval (R5 throttle).
const Duration kProgressThrottle = Duration(milliseconds: 200);

/// Application-level download manager (PRD R1–R7):
/// - bounded concurrency queue, default 3, adjustable for new dispatches;
/// - strict streaming (transport chunks → pending sink, no full-file bytes);
/// - dedupe by request identity while a task is non-terminal;
/// - queued/running cancellation, failed/canceled retry;
/// - exactly one terminal event per task; throttled progress snapshots;
/// - MediaStore pending finalize/abort semantics.
class DownloadManager {
  DownloadManager({
    required DownloadTransport transport,
    required DownloadSinkFactory sinkFactory,
    int maxConcurrent = 3,
    this.progressThrottle = kProgressThrottle,
  })  : _transport = transport,
        _sinkFactory = sinkFactory,
        _maxConcurrent = maxConcurrent;

  final DownloadTransport _transport;
  final DownloadSinkFactory _sinkFactory;
  final Duration progressThrottle;

  int _maxConcurrent;
  int get maxConcurrent => _maxConcurrent;

  /// Applies a new concurrency limit; running tasks are untouched and the
  /// scheduler enforces the new cap for every subsequent dispatch (R1/AC).
  set maxConcurrent(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'maxConcurrent', 'must be >= 1');
    }
    _maxConcurrent = value;
    _schedule();
  }

  final Map<String, _Job> _jobs = {};
  final StreamController<DownloadEvent> _events =
      StreamController<DownloadEvent>.broadcast();

  /// Terminal events, exactly one per task attempt-completion (R3).
  Stream<DownloadEvent> get events => _events.stream;

  /// Read-only snapshots for UI lists (progress values are throttled).
  List<DownloadTaskSnapshot> get tasks =>
      _jobs.values.map((job) => job.snapshot).toList(growable: false);

  DownloadTaskSnapshot? taskById(String id) => _findById(id)?.snapshot;

  /// Submits a request. Returns the existing non-terminal task when the
  /// dedupe key matches (AC: 同一目标不会重复启动), otherwise the new queued
  /// task. Throws [FormatException] for unsafe URLs/names (R4/R7).
  DownloadTaskSnapshot submit(DownloadRequest request) {
    validateDownloadUrl(request.url);
    final name = request.displayName;
    validateDisplayName(name);

    final key = request.dedupeKey;
    final existing = _jobs[key];
    if (existing != null && !isTerminal(existing.snapshot.status)) {
      return existing.snapshot;
    }

    final id = '${request.illustId}_${request.pageIndex}_${_nextSeq++}';
    final job = _Job(
      id: id,
      key: key,
      request: request,
      displayName: name,
    );
    _jobs[key] = job;
    _schedule();
    return job.snapshot;
  }

  /// Cancels a queued (immediately terminal) or running task (observable
  /// `canceling` while the transfer unwinds). Unknown/terminal ids are no-ops.
  Future<void> cancel(String taskId) async {
    final job = _findById(taskId);
    if (job == null || isTerminal(job.snapshot.status)) {
      return;
    }
    switch (job.snapshot.status) {
      case DownloadStatus.queued:
        job.applySnapshot(
          job.snapshot.copyWith(status: DownloadStatus.canceled),
        );
        _complete(job, DownloadEvent.canceled(job.snapshot));
        _schedule();
      case DownloadStatus.running:
      case DownloadStatus.canceling:
        job.applySnapshot(
          job.snapshot.copyWith(
            status: job.snapshot.status == DownloadStatus.running
                ? DownloadStatus.canceling
                : job.snapshot.status,
          ),
        );
        job.cancelToken.cancel();
      case DownloadStatus.succeeded:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        return;
    }
  }

  /// Retries a failed or canceled task by resubmitting its request (R5).
  /// Returns the new task snapshot, or null when the id is unknown or not
  /// retryable.
  DownloadTaskSnapshot? retry(String taskId) {
    final job = _findById(taskId);
    if (job == null) {
      return null;
    }
    if (job.snapshot.status != DownloadStatus.failed &&
        job.snapshot.status != DownloadStatus.canceled) {
      return null;
    }
    _jobs.remove(job.key);
    return submit(job.request);
  }

  _Job? _findById(String taskId) {
    for (final job in _jobs.values) {
      if (job.id == taskId) {
        return job;
      }
    }
    return null;
  }

  var _nextSeq = 0;

  void _schedule() {
    var running = 0;
    for (final job in _jobs.values) {
      if (job.snapshot.status == DownloadStatus.running ||
          job.snapshot.status == DownloadStatus.canceling) {
        running++;
      }
    }
    for (final job in _jobs.values) {
      if (running >= _maxConcurrent) break;
      if (job.snapshot.status != DownloadStatus.queued) continue;
      running++;
      _run(job);
    }
  }

  Future<void> _run(_Job job) async {
    job.applySnapshot(job.snapshot.copyWith(status: DownloadStatus.running));
    job.cancelToken = DownloadCancelToken();
    DownloadSink? sink;
    DownloadResponse? response;
    try {
      sink = await _sinkFactory.begin(job.request, job.displayName);
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      response = await _transport.open(
        job.request.url,
        headers: {
          'User-Agent': PixivClientIdentity.userAgent,
          'Referer': PixivClientIdentity.downloadReferer.toString(),
        },
        cancelToken: job.cancelToken,
      );
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      job.applySnapshot(
        job.snapshot.copyWith(
          totalBytes: response.contentLength,
          receivedBytes: 0,
        ),
      );

      var received = 0;
      var lastEmit = DateTime.now();
      await for (final chunk in response.stream) {
        if (job.cancelToken.isCancelled) {
          throw const DownloadCancelledException();
        }
        await sink.write(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastEmit) >= progressThrottle) {
          lastEmit = now;
          job.applySnapshot(
            job.snapshot.copyWith(receivedBytes: received),
          );
        }
      }
      // Stream drained; apply the final byte count before finalize.
      job.applySnapshot(
        job.snapshot.copyWith(
          receivedBytes: received,
          status: DownloadStatus.succeeded,
        ),
      );
      await sink.finalize();
      _complete(job, DownloadEvent.succeeded(job.snapshot));
    } on DownloadCancelledException {
      await sink?.abort();
      await response?.close();
      job.applySnapshot(
        job.snapshot.copyWith(status: DownloadStatus.canceled),
      );
      _complete(job, DownloadEvent.canceled(job.snapshot));
    } catch (error) {
      await sink?.abort();
      await response?.close();
      job.applySnapshot(
        job.snapshot.copyWith(
          status: DownloadStatus.failed,
          error: error.toString(),
        ),
      );
      _complete(job, DownloadEvent.failed(job.snapshot, error.toString()));
    }
    _schedule();
  }

  /// Emits the single terminal event for [job]; guarded so double
  /// finalization can never produce two events (R3/AC).
  void _complete(_Job job, DownloadEvent event) {
    if (job.terminalEmitted) {
      return;
    }
    job.terminalEmitted = true;
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  /// Closes the event stream and tears down transport resources.
  Future<void> dispose() async {
    for (final job in _jobs.values) {
      if (!isTerminal(job.snapshot.status)) {
        job.cancelToken.cancel();
      }
    }
    await _events.close();
    final transport = _transport;
    if (transport is HttpDownloadTransport) {
      await transport.dispose();
    }
  }
}

class _Job {
  _Job({
    required this.id,
    required this.key,
    required this.request,
    required this.displayName,
  });

  final String id;
  final String key;
  final DownloadRequest request;
  final String displayName;

  DownloadCancelToken cancelToken = DownloadCancelToken();
  late DownloadTaskSnapshot snapshot = DownloadTaskSnapshot(
    id: id,
    illustId: request.illustId,
    pageIndex: request.pageIndex,
    url: request.url,
    target: request.target.name,
    displayName: displayName,
    status: DownloadStatus.queued,
  );
  var terminalEmitted = false;

  void applySnapshot(DownloadTaskSnapshot value) {
    snapshot = value;
  }
}
