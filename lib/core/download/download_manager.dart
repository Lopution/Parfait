import 'dart:async';
import 'dart:io';

import '../network/compat/network_contracts.dart';
import '../network/pixiv_client_identity.dart';
import '../platform/android_platform_interfaces.dart';
import 'download_recovery.dart';
import 'download_request.dart';
import 'download_sink.dart';
import 'download_task.dart';
import 'download_transport.dart';
import 'pixiv_download_transport.dart';

/// Per-task progress snapshot emission interval (R5 throttle).
const Duration kProgressThrottle = Duration(milliseconds: 200);

typedef DownloadSubmissionContextProvider =
    DownloadSubmissionContext? Function();

/// Application-level download manager (PRD R1–R7).
///
/// The manager owns the job state machine and output cleanup boundary. A
/// caller may use the legacy unowned mode for local/unit adapters, while the
/// app-scoped provider enables [requireOwnedSubmissions] and supplies the
/// account/credential/network snapshot for every product download.
class DownloadManager {
  DownloadManager({
    required DownloadTransport transport,
    required DownloadSinkFactory sinkFactory,
    int maxConcurrent = 3,
    this.progressThrottle = kProgressThrottle,
    DownloadSubmissionContextProvider? submissionContext,
    DownloadRecoveryStore? recoveryStore,
    this.requireOwnedSubmissions = false,
    this.enforceDefaultDestination = true,
    DateTime Function()? now,
  }) : _transport = transport,
       _sinkFactory = sinkFactory,
       _maxConcurrent = maxConcurrent,
       _submissionContext = submissionContext,
       _recoveryStore = recoveryStore ?? MemoryDownloadRecoveryStore(),
       _now = now ?? DateTime.now;

  final DownloadTransport _transport;
  final DownloadSinkFactory _sinkFactory;
  final Duration progressThrottle;
  final DownloadSubmissionContextProvider? _submissionContext;
  final DownloadRecoveryStore _recoveryStore;
  final bool requireOwnedSubmissions;

  /// MediaStore-backed app downloads keep the public destination contract.
  /// Internal app-private jobs (such as a signed updater APK) may opt out
  /// while retaining the same owner/revision checks.
  final bool enforceDefaultDestination;
  final DateTime Function() _now;

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
  final Map<String, _DownloadGroup> _groups = {};
  final Set<Future<void>> _activeRuns = {};
  final StreamController<DownloadEvent> _events =
      StreamController<DownloadEvent>.broadcast();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Future<void> _persistenceTail = Future<void>.value();
  Future<DownloadRecoveryReport>? _recoveryInFlight;
  Object? _lastRecoveryError;
  var _nextSeq = 0;
  var _nextGroupSeq = 0;
  var _disposed = false;

  /// The last persistence/recovery error is observable to settings and
  /// diagnostics; it is never converted into a successful empty result.
  Object? get lastRecoveryError => _lastRecoveryError;

  /// Terminal events, exactly one per task attempt-completion (R3).
  Stream<DownloadEvent> get events => _events.stream;

  /// State changes include recovery and progress updates, which are not
  /// terminal events but still need to refresh task-list consumers.
  Stream<void> get changes => _changes.stream;

  /// Read-only snapshots for UI lists (progress values are throttled).
  List<DownloadTaskSnapshot> get tasks =>
      _jobs.values.map((job) => job.snapshot).toList(growable: false);

  List<DownloadGroupSnapshot> get groups =>
      _groups.values.map(_groupSnapshot).toList(growable: false);

  DownloadTaskSnapshot? taskById(String id) => _findById(id)?.snapshot;

  DownloadGroupSnapshot? groupById(String id) {
    final group = _groups[id];
    return group == null ? null : _groupSnapshot(group);
  }

  /// Submits one request with an immutable account/target/policy boundary.
  /// Returns the existing non-terminal task when the full identity (including
  /// owner and policy revision) matches.
  DownloadTaskSnapshot submit(
    DownloadRequest request, {
    String? groupId,
    DownloadSubmissionContext? context,
  }) {
    _checkUsable();
    validateDownloadUrl(request.url, target: request.target);
    final name = request.displayName;
    validateDisplayName(name);

    final ownerContext = context ?? _submissionContext?.call();
    if (requireOwnedSubmissions && ownerContext == null) {
      throw const DownloadOwnershipException(
        'an authenticated submission boundary is required',
      );
    }
    if (ownerContext != null &&
        (ownerContext.accountId.isEmpty ||
            (enforceDefaultDestination &&
                ownerContext.destination != kDownloadDestination))) {
      throw const DownloadOwnershipException(
        'submission destination or account owner is invalid',
      );
    }
    final key = _identityKey(request, ownerContext);
    final existing = _jobs[key];
    if (existing != null && !isTerminal(existing.snapshot.status)) {
      return existing.snapshot;
    }

    final id = 'download_${request.illustId}_${request.pageIndex}_$_nextSeq';
    _nextSeq++;
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission_$id',
      jobId: id,
      groupId: groupId,
      request: request,
      accountId: ownerContext?.accountId,
      credentialRevision: ownerContext?.credentialRevision ?? 0,
      submittedAt: _now().toUtc(),
      destination: ownerContext?.destination ?? kDownloadDestination,
    );
    final owner = DownloadOutputOwner(
      ownerId: 'output_$id',
      jobId: id,
      accountId: snapshot.accountId,
    );
    final job = _Job(
      id: id,
      key: key,
      request: request,
      displayName: name,
      submission: snapshot,
      owner: owner,
    );
    _jobs[key] = job;
    _notifyChange();
    _persist(job);
    _schedule();
    return job.snapshot;
  }

  /// Creates an explicit group for Download All and Ugoira-style multi-step
  /// work. All children capture one submission context before any dispatch.
  DownloadGroupSnapshot submitGroup(
    List<DownloadRequest> requests, {
    String? groupId,
    DownloadSubmissionContext? context,
  }) {
    _checkUsable();
    if (requests.isEmpty) {
      throw ArgumentError('a download group must contain a request');
    }
    final resolvedGroupId = groupId ?? 'download_group_${_nextGroupSeq++}';
    final ownerContext = context ?? _submissionContext?.call();
    final children = [
      for (final request in requests)
        submit(request, groupId: resolvedGroupId, context: ownerContext),
    ];
    final submission = children.first.submission;
    if (submission == null) {
      throw StateError('download group child has no submission snapshot');
    }
    _groups[resolvedGroupId] = _DownloadGroup(
      id: resolvedGroupId,
      jobIds: [for (final child in children) child.id],
      submission: submission,
    );
    return _groupSnapshot(_groups[resolvedGroupId]!);
  }

  /// Cancels a queued/retryable task immediately or asks a running transfer
  /// to unwind. Once finalization has started, cancellation cannot make an
  /// already-visible output disappear; the finalization result wins.
  Future<void> cancel(String taskId) async {
    final job = _findById(taskId);
    if (job == null || isTerminal(job.snapshot.status)) return;
    switch (job.snapshot.status) {
      case DownloadStatus.queued:
      case DownloadStatus.retryable:
        _transition(job, DownloadStatus.canceled);
        _complete(job, DownloadEvent.canceled(job.snapshot));
        _schedule();
      case DownloadStatus.running:
        _transition(job, DownloadStatus.canceling);
        job.cancelToken.cancel();
      case DownloadStatus.canceling:
        job.cancelToken.cancel();
      case DownloadStatus.finalizing:
        job.cancelToken.cancel();
      case DownloadStatus.succeeded:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
      case DownloadStatus.orphaned:
        return;
    }
  }

  /// Retries failed/canceled/recovered work as a new attempt. A new immutable
  /// snapshot is captured, so changing account or policy cannot reuse the old
  /// attempt's owner boundary.
  DownloadTaskSnapshot? retry(String taskId) {
    final job = _findById(taskId);
    if (job == null ||
        (job.snapshot.status != DownloadStatus.failed &&
            job.snapshot.status != DownloadStatus.canceled &&
            job.snapshot.status != DownloadStatus.retryable)) {
      return null;
    }
    _jobs.remove(job.key);
    _persistRemove(job.id);
    final oldJobId = job.id;
    final groupId = job.snapshot.groupId;
    final retried = submit(job.request, groupId: groupId);
    final group = groupId == null ? null : _groups[groupId];
    if (group != null) {
      final index = group.jobIds.indexOf(oldJobId);
      if (index >= 0) {
        group.jobIds[index] = retried.id;
      } else if (!group.jobIds.contains(retried.id)) {
        group.jobIds.add(retried.id);
      }
    }
    return retried;
  }

  /// Scans durable metadata after process start. Only a complete record whose
  /// account, credential revision, network revision and destination still
  /// match the current context becomes [DownloadStatus.retryable]. Recovery
  /// never auto-retries a transfer or post-process operation.
  Future<DownloadRecoveryReport> recover({
    DownloadSubmissionContext? currentContext,
  }) {
    final existing = _recoveryInFlight;
    if (existing != null) return existing;
    final future = _recover(currentContext: currentContext);
    _recoveryInFlight = future;
    unawaited(
      future.whenComplete(() {
        _recoveryInFlight = null;
      }),
    );
    return future;
  }

  Future<DownloadRecoveryReport> _recover({
    required DownloadSubmissionContext? currentContext,
  }) async {
    await flushPersistence();
    final context = currentContext ?? _submissionContext?.call();
    List<DownloadRecoveryRecord> records;
    try {
      records = await _recoveryStore.load();
    } on Object catch (error) {
      _lastRecoveryError = error;
      return DownloadRecoveryReport(error: error);
    }

    Object? recoveryError;
    final pendingItems = <PendingMediaStoreItem>[];
    if (_sinkFactory is RecoverableDownloadSinkFactory) {
      final recoverableFactory = _sinkFactory as RecoverableDownloadSinkFactory;
      try {
        pendingItems.addAll(await recoverableFactory.listPending());
      } on Object catch (error) {
        _lastRecoveryError = error;
        recoveryError = error;
      }
    }
    final pendingByOwner = <String, PendingMediaStoreItem>{};
    for (final item in pendingItems) {
      final ownerId = item.ownerId;
      if (ownerId != null) pendingByOwner[ownerId] = item;
    }

    final retryable = <String>[];
    final orphaned = <String>[];
    final orphanedPending = <int>{};
    final restored = <String>[];
    final skipped = <String>[];
    final cleanupFailed = <String>{};
    final cleanupFailedPending = <int>{};
    final matchedPending = <int>{};
    final recordsByOwner = <String, DownloadRecoveryRecord>{};
    for (final record in records) {
      recordsByOwner[record.owner.ownerId] = record;
    }
    for (final record in records) {
      if (_findById(record.jobId) != null) {
        skipped.add(record.jobId);
        continue;
      }
      final scannedPending = pendingByOwner[record.owner.ownerId];
      final pendingId = record.pendingMediaStoreId ?? scannedPending?.id;
      if (pendingId != null) matchedPending.add(pendingId);
      var cleanupOk = true;
      if (pendingId != null && record.status != DownloadStatus.succeeded) {
        cleanupOk = await _cleanupPendingOutput(pendingId, record.owner);
        if (!cleanupOk) {
          cleanupFailed.add(record.jobId);
          cleanupFailedPending.add(pendingId);
        }
      }
      if (record.status == DownloadStatus.succeeded && pendingId != null) {
        // A successful durable record must never cause a pending row to be
        // deleted speculatively; surface the contradictory row instead.
        orphanedPending.add(pendingId);
      }

      // Without a usable account there is no UI owner boundary to restore,
      // but known pending rows can still be cleaned through their exact
      // opaque owner. The durable record remains for a later signed-in scan.
      if (context == null) continue;
      final request = record.snapshot.request;
      try {
        validateDownloadUrl(request.url, target: request.target);
        validateDisplayName(request.displayName);
      } on Object catch (error) {
        final job = _recoveredJob(
          record,
          status: DownloadStatus.orphaned,
          error: 'recovery record rejected: ${error.runtimeType}',
          failureKind: DownloadFailureKind.ownership,
        );
        if (cleanupOk) job.pendingOutputId = null;
        _jobs[record.dedupeKey] = job;
        _notifyChange();
        _registerRecoveredGroup(job);
        _complete(
          job,
          DownloadEvent.orphaned(job.snapshot, job.snapshot.error),
        );
        orphaned.add(record.jobId);
        continue;
      }

      final owned =
          record.snapshot.jobId == record.jobId &&
          record.owner.jobId == record.jobId &&
          _sameContext(record.snapshot, context) &&
          record.owner.accountId == context.accountId;
      final pending = !isTerminal(record.status);
      if (pending && !owned) {
        final job = _recoveredJob(
          record,
          status: DownloadStatus.orphaned,
          error: 'recovery output owner does not match the current account',
          failureKind: DownloadFailureKind.ownership,
        );
        if (cleanupOk) job.pendingOutputId = null;
        _jobs[record.dedupeKey] = job;
        _notifyChange();
        _registerRecoveredGroup(job);
        _complete(
          job,
          DownloadEvent.orphaned(job.snapshot, job.snapshot.error),
        );
        orphaned.add(record.jobId);
        continue;
      }

      final finalizationInterrupted =
          record.status == DownloadStatus.finalizing;
      final status = finalizationInterrupted
          ? DownloadStatus.orphaned
          : pending
          ? DownloadStatus.retryable
          : record.status;
      final job = _recoveredJob(
        record,
        status: status,
        error: finalizationInterrupted
            ? 'process restarted during output finalization; output state requires inspection'
            : pending
            ? cleanupFailed.contains(record.jobId)
                  ? 'process restarted; pending output cleanup needs attention'
                  : 'process restarted; explicit retry is required'
            : record.error,
        failureKind: finalizationInterrupted
            ? DownloadFailureKind.ownership
            : record.failureKind,
      );
      if (cleanupOk) job.pendingOutputId = null;
      _jobs[record.dedupeKey] = job;
      _notifyChange();
      _registerRecoveredGroup(job);
      _persist(job);
      if (finalizationInterrupted) {
        orphaned.add(record.jobId);
        _complete(
          job,
          DownloadEvent.orphaned(job.snapshot, job.snapshot.error),
        );
      } else if (pending) {
        retryable.add(record.jobId);
      } else {
        restored.add(record.jobId);
        if (isTerminal(status)) job.terminalEmitted = true;
      }
    }

    // Rows without a matching durable owner record are never deleted. A
    // process may have crashed before the Dart metadata write completed, so
    // the only safe outcome is an observable orphan for later inspection.
    for (final item in pendingItems) {
      if (matchedPending.contains(item.id)) continue;
      final ownerId = item.ownerId;
      final record = ownerId == null ? null : recordsByOwner[ownerId];
      if (record == null || record.status == DownloadStatus.succeeded) {
        orphanedPending.add(item.id);
        continue;
      }
      final cleanupOk = await _cleanupPendingOutput(item.id, record.owner);
      if (!cleanupOk) {
        cleanupFailed.add(record.jobId);
        cleanupFailedPending.add(item.id);
      }
    }
    return DownloadRecoveryReport(
      retryableJobIds: retryable,
      orphanedJobIds: orphaned,
      orphanedPendingOutputIds: orphanedPending.toList(growable: false),
      restoredJobIds: restored,
      skippedJobIds: skipped,
      cleanupFailedJobIds: cleanupFailed.toList(growable: false),
      cleanupFailedPendingOutputIds: cleanupFailedPending.toList(
        growable: false,
      ),
      error: recoveryError,
    );
  }

  /// Waits for queued metadata writes. Tests and lifecycle owners use this to
  /// make a restart fixture deterministic.
  Future<void> flushPersistence() => _persistenceTail;

  /// Cancels active work whose owner no longer matches the current account or
  /// policy boundary. The run is reported as [DownloadStatus.orphaned] after
  /// its own sink cleanup, so an account switch cannot silently reuse it.
  void invalidateStaleSubmissions() {
    final context = _submissionContext?.call();
    for (final job in _jobs.values) {
      if (isTerminal(job.snapshot.status) || !job.submission.isOwned) continue;
      if (context == null || !_sameContext(job.submission, context)) {
        job.ownerInvalidated = true;
        job.cancelToken.cancel();
      }
    }
  }

  _Job? _findById(String taskId) {
    for (final job in _jobs.values) {
      if (job.id == taskId) return job;
    }
    return null;
  }

  String _identityKey(
    DownloadRequest request,
    DownloadSubmissionContext? context,
  ) {
    final owner = context == null
        ? 'unowned'
        : '${context.accountId}|${context.credentialRevision}|'
              '${context.destination}';
    return '${request.dedupeKey}|$owner';
  }

  void _schedule() {
    if (_disposed) return;
    var active = 0;
    for (final job in _jobs.values) {
      if (job.snapshot.status == DownloadStatus.running ||
          job.snapshot.status == DownloadStatus.canceling ||
          job.snapshot.status == DownloadStatus.finalizing) {
        active++;
      }
    }
    for (final job in _jobs.values) {
      if (active >= _maxConcurrent) break;
      if (job.snapshot.status != DownloadStatus.queued) continue;
      active++;
      _start(job);
    }
  }

  void _start(_Job job) {
    final future = _run(job);
    _activeRuns.add(future);
    unawaited(
      future.then<void>(
        (_) => _activeRuns.remove(future),
        onError: (Object _, StackTrace _) {
          _activeRuns.remove(future);
        },
      ),
    );
  }

  Future<void> _run(_Job job) async {
    job.cancelToken = DownloadCancelToken();
    _transition(job, DownloadStatus.running);
    DownloadSink? sink;
    DownloadResponse? response;
    var responseClosed = false;
    late Future<void> Function() closeResponse;
    closeResponse = () async {
      if (responseClosed) return;
      responseClosed = true;
      final current = response;
      response = null;
      if (current == null) return;
      try {
        await current.close();
      } catch (_) {
        // Closing a drained/canceled transport must not mask its task result.
      }
    };
    try {
      _checkOwner(job);
      sink = await _beginSink(job);
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      if (sink is DownloadSinkOutputMetadata) {
        job.pendingOutputId =
            (sink as DownloadSinkOutputMetadata).pendingOutputId;
        _persist(job);
      }
      _checkOwner(job);
      final openedResponse = await _transport.open(
        job.request.url,
        headers: {
          'User-Agent': PixivClientIdentity.userAgent,
          'Referer': PixivClientIdentity.downloadReferer.toString(),
        },
        cancelToken: job.cancelToken,
      );
      response = openedResponse;
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      if (openedResponse.statusCode < 200 || openedResponse.statusCode >= 300) {
        throw DownloadHttpStatusException(
          openedResponse.statusCode,
          job.request.url,
          retryAfter: _retryAfter(openedResponse),
        );
      }
      _checkOwner(job);
      _update(
        job,
        job.snapshot.copyWith(
          totalBytes: openedResponse.contentLength,
          receivedBytes: 0,
        ),
      );

      var received = 0;
      var lastEmit = _now();
      await for (final chunk in openedResponse.stream) {
        if (job.cancelToken.isCancelled) {
          throw const DownloadCancelledException();
        }
        _checkOwner(job);
        await sink.write(chunk);
        received += chunk.length;
        final now = _now();
        if (now.difference(lastEmit) >= progressThrottle) {
          lastEmit = now;
          _update(job, job.snapshot.copyWith(receivedBytes: received));
        }
      }
      _update(job, job.snapshot.copyWith(receivedBytes: received));
      await closeResponse();
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      _checkOwner(job);
      _transition(job, DownloadStatus.finalizing);
      final uri = Uri.parse(await sink.finalize());
      // Once finalize has started, a late cancellation cannot undo a visible
      // MediaStore row. Report the one durable result rather than lying about
      // cleanup.
      job.pendingOutputId = null;
      _transition(job, DownloadStatus.succeeded);
      _update(
        job,
        job.snapshot.copyWith(
          finalUri: uri,
          error: null,
          failureKind: null,
          retryAfter: null,
        ),
      );
      _complete(job, DownloadEvent.succeeded(job.snapshot));
    } on DownloadCancelledException {
      await _abortOnce(job, sink);
      await closeResponse();
      if (job.ownerInvalidated) {
        _transition(job, DownloadStatus.orphaned);
        _update(
          job,
          job.snapshot.copyWith(
            error: 'download owner changed while task was active',
            failureKind: DownloadFailureKind.ownership,
          ),
        );
        _complete(
          job,
          DownloadEvent.orphaned(job.snapshot, job.snapshot.error),
        );
      } else {
        _transition(job, DownloadStatus.canceled);
        _update(
          job,
          job.snapshot.copyWith(
            error: 'download canceled',
            failureKind: DownloadFailureKind.canceled,
          ),
        );
        _complete(job, DownloadEvent.canceled(job.snapshot));
      }
    } on DownloadOwnershipException catch (error) {
      await _abortOnce(job, sink);
      await closeResponse();
      _transition(job, DownloadStatus.orphaned);
      _update(
        job,
        job.snapshot.copyWith(
          error: error.toString(),
          failureKind: DownloadFailureKind.ownership,
        ),
      );
      _complete(job, DownloadEvent.orphaned(job.snapshot, job.snapshot.error));
    } catch (error) {
      await _abortOnce(job, sink);
      await closeResponse();
      // Some transports surface socket teardown as a generic transport
      // error instead of DownloadCancelledException. Once cancellation has
      // been requested before finalization, the user/owner boundary still
      // wins over that secondary teardown error.
      if (job.cancelToken.isCancelled &&
          job.snapshot.status != DownloadStatus.finalizing) {
        if (job.ownerInvalidated) {
          _transition(job, DownloadStatus.orphaned);
          _update(
            job,
            job.snapshot.copyWith(
              error: 'download owner changed while task was active',
              failureKind: DownloadFailureKind.ownership,
            ),
          );
          _complete(
            job,
            DownloadEvent.orphaned(job.snapshot, job.snapshot.error),
          );
        } else {
          _transition(job, DownloadStatus.canceled);
          _update(
            job,
            job.snapshot.copyWith(
              error: 'download canceled',
              failureKind: DownloadFailureKind.canceled,
            ),
          );
          _complete(job, DownloadEvent.canceled(job.snapshot));
        }
      } else {
        final failureKind = classifyDownloadFailure(error);
        _transition(job, DownloadStatus.failed);
        _update(
          job,
          job.snapshot.copyWith(
            error: _safeError(error),
            failureKind: failureKind,
            retryAfter: _retryAfterFromError(error),
          ),
        );
        _complete(job, DownloadEvent.failed(job.snapshot, job.snapshot.error));
      }
    } finally {
      if (!responseClosed) await closeResponse();
      _schedule();
    }
  }

  Future<DownloadSink> _beginSink(_Job job) {
    final factory = _sinkFactory;
    if (factory is OwnedDownloadSinkFactory) {
      return (factory as OwnedDownloadSinkFactory).beginOwned(
        job.request,
        job.displayName,
        job.owner,
      );
    }
    return factory.begin(job.request, job.displayName);
  }

  void _checkOwner(_Job job) {
    final snapshot = job.submission;
    if (!snapshot.isOwned || _submissionContext == null) return;
    final current = _submissionContext();
    if (current == null || !_sameContext(snapshot, current)) {
      job.ownerInvalidated = true;
      throw const DownloadOwnershipException(
        'submission owner changed before output write/finalize',
      );
    }
  }

  bool _sameContext(
    DownloadSubmissionSnapshot snapshot,
    DownloadSubmissionContext context,
  ) {
    return snapshot.accountId == context.accountId &&
        snapshot.credentialRevision == context.credentialRevision &&
        snapshot.destination == context.destination;
  }

  DownloadRecoveryRecord _record(_Job job) {
    return DownloadRecoveryRecord(
      jobId: job.id,
      dedupeKey: job.key,
      snapshot: job.submission,
      owner: job.owner,
      status: job.snapshot.status,
      receivedBytes: job.snapshot.receivedBytes,
      totalBytes: job.snapshot.totalBytes,
      pendingMediaStoreId: job.pendingOutputId,
      finalUri: job.snapshot.finalUri?.toString(),
      error: job.snapshot.error,
      failureKind: job.snapshot.failureKind,
      retryAfter: job.snapshot.retryAfter,
    );
  }

  _Job _recoveredJob(
    DownloadRecoveryRecord record, {
    required DownloadStatus status,
    required String? error,
    required DownloadFailureKind? failureKind,
  }) {
    final snapshot = DownloadTaskSnapshot(
      id: record.jobId,
      illustId: record.snapshot.illustId,
      pageIndex: record.snapshot.pageIndex,
      url: record.snapshot.sourceUrl,
      target: record.snapshot.target.name,
      displayName: record.snapshot.displayName,
      status: status,
      receivedBytes: record.receivedBytes,
      totalBytes: record.totalBytes,
      error: error,
      failureKind: failureKind,
      retryAfter: record.retryAfter,
      finalUri: record.finalUri == null ? null : Uri.tryParse(record.finalUri!),
      submission: record.snapshot,
      outputOwner: record.owner,
    );
    final job = _Job(
      id: record.jobId,
      key: record.dedupeKey,
      request: record.snapshot.request,
      displayName: record.snapshot.displayName,
      submission: record.snapshot,
      owner: record.owner,
      snapshot: snapshot,
    );
    job.pendingOutputId = record.pendingMediaStoreId;
    return job;
  }

  void _transition(_Job job, DownloadStatus next) {
    final current = job.snapshot.status;
    if (current == next) return;
    if (!_allowedTransition(current, next)) {
      throw StateError(
        'invalid download transition ${current.name} -> ${next.name}',
      );
    }
    _update(job, job.snapshot.copyWith(status: next));
  }

  bool _allowedTransition(DownloadStatus from, DownloadStatus to) {
    return switch (from) {
      DownloadStatus.queued =>
        to == DownloadStatus.running ||
            to == DownloadStatus.canceled ||
            to == DownloadStatus.retryable ||
            to == DownloadStatus.orphaned,
      DownloadStatus.running =>
        to == DownloadStatus.canceling ||
            to == DownloadStatus.finalizing ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.canceled ||
            to == DownloadStatus.orphaned,
      DownloadStatus.canceling =>
        to == DownloadStatus.canceled ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.orphaned,
      DownloadStatus.finalizing =>
        to == DownloadStatus.succeeded ||
            to == DownloadStatus.failed ||
            to == DownloadStatus.canceled ||
            to == DownloadStatus.orphaned,
      DownloadStatus.retryable =>
        to == DownloadStatus.queued ||
            to == DownloadStatus.canceled ||
            to == DownloadStatus.orphaned,
      DownloadStatus.succeeded ||
      DownloadStatus.failed ||
      DownloadStatus.canceled ||
      DownloadStatus.orphaned => false,
    };
  }

  void _update(_Job job, DownloadTaskSnapshot snapshot) {
    job.applySnapshot(snapshot);
    _notifyChange();
    _persist(job);
  }

  void _notifyChange() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Emits the single terminal event for [job]; guarded so duplicate
  /// callbacks/finalizers can never produce two terminal events.
  void _complete(_Job job, DownloadEvent event) {
    if (job.terminalEmitted) return;
    job.terminalEmitted = true;
    _persist(job);
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _abortOnce(_Job job, DownloadSink? sink) async {
    if (job.cleanupStarted) return;
    job.cleanupStarted = true;
    if (sink == null) return;
    try {
      await sink.abort();
    } catch (_) {
      // Cleanup cannot mask the original failure. The durable owner record
      // remains available for a later platform-level orphan scan.
    }
  }

  Future<bool> _cleanupPendingOutput(int id, DownloadOutputOwner owner) async {
    final factory = _sinkFactory;
    if (factory is! RecoverableDownloadSinkFactory) return false;
    try {
      return await (factory as RecoverableDownloadSinkFactory).cleanupPending(
        id,
        owner: owner,
      );
    } on Object catch (error) {
      _lastRecoveryError = error;
      return false;
    }
  }

  void _persist(_Job job) {
    final record = _record(job);
    final next = _persistenceTail.then((_) async {
      try {
        await _recoveryStore.upsert(record);
      } on Object catch (error) {
        _lastRecoveryError = error;
      }
    });
    _persistenceTail = next;
  }

  void _persistRemove(String jobId) {
    final next = _persistenceTail.then((_) async {
      try {
        await _recoveryStore.remove(jobId);
      } on Object catch (error) {
        _lastRecoveryError = error;
      }
    });
    _persistenceTail = next;
  }

  DownloadGroupSnapshot _groupSnapshot(_DownloadGroup group) {
    final childStatuses = [
      for (final id in group.jobIds) _findById(id)?.snapshot.status,
    ].whereType<DownloadStatus>().toList(growable: false);
    return DownloadGroupSnapshot(
      id: group.id,
      jobIds: List.unmodifiable(group.jobIds),
      submission: group.submission,
      status: _aggregateGroupStatus(childStatuses),
    );
  }

  void _registerRecoveredGroup(_Job job) {
    final groupId = job.submission.groupId;
    if (groupId == null || groupId.isEmpty) return;
    final group = _groups[groupId];
    if (group == null) {
      _groups[groupId] = _DownloadGroup(
        id: groupId,
        jobIds: [job.id],
        submission: job.submission,
      );
    } else if (!group.jobIds.contains(job.id)) {
      group.jobIds.add(job.id);
    }
  }

  DownloadGroupStatus _aggregateGroupStatus(List<DownloadStatus> statuses) {
    if (statuses.isEmpty ||
        statuses.any((value) => value == DownloadStatus.queued)) {
      return DownloadGroupStatus.queued;
    }
    if (statuses.any((value) => value == DownloadStatus.orphaned)) {
      return DownloadGroupStatus.orphaned;
    }
    if (statuses.any((value) => value == DownloadStatus.failed)) {
      return DownloadGroupStatus.failed;
    }
    if (statuses.any((value) => value == DownloadStatus.finalizing)) {
      return DownloadGroupStatus.finalizing;
    }
    if (statuses.any(
      (value) =>
          value == DownloadStatus.running || value == DownloadStatus.canceling,
    )) {
      return DownloadGroupStatus.running;
    }
    if (statuses.any((value) => value == DownloadStatus.retryable)) {
      return DownloadGroupStatus.retryable;
    }
    if (statuses.every((value) => value == DownloadStatus.succeeded)) {
      return DownloadGroupStatus.succeeded;
    }
    return DownloadGroupStatus.canceled;
  }

  void _checkUsable() {
    if (_disposed) throw StateError('download manager is disposed');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final job in _jobs.values.toList(growable: false)) {
      if (job.snapshot.status == DownloadStatus.queued ||
          job.snapshot.status == DownloadStatus.retryable) {
        _transition(job, DownloadStatus.canceled);
        _complete(job, DownloadEvent.canceled(job.snapshot));
      } else if (!isTerminal(job.snapshot.status)) {
        job.cancelToken.cancel();
      }
    }
    // Do not make disposal depend on a transport honoring cancellation. A
    // process may be torn down while a platform stream is wedged; the
    // persisted canceling/running record is intentionally left for the next
    // recovery scan to classify. Cooperative transports still settle their
    // own futures after this method returns.
    await flushPersistence();
    await _events.close();
    await _changes.close();
    final transport = _transport;
    if (transport is DisposableDownloadTransport) {
      await (transport as DisposableDownloadTransport).dispose();
    }
  }
}

class _Job {
  _Job({
    required this.id,
    required this.key,
    required this.request,
    required this.displayName,
    required this.submission,
    required this.owner,
    DownloadTaskSnapshot? snapshot,
  }) : snapshot =
           snapshot ??
           DownloadTaskSnapshot(
             id: id,
             illustId: request.illustId,
             pageIndex: request.pageIndex,
             url: request.url,
             target: request.target.name,
             displayName: displayName,
             status: DownloadStatus.queued,
             submission: submission,
             outputOwner: owner,
           );

  final String id;
  final String key;
  final DownloadRequest request;
  final String displayName;
  final DownloadSubmissionSnapshot submission;
  final DownloadOutputOwner owner;

  DownloadCancelToken cancelToken = DownloadCancelToken();
  DownloadTaskSnapshot snapshot;
  var terminalEmitted = false;
  var cleanupStarted = false;
  int? pendingOutputId;
  var ownerInvalidated = false;

  void applySnapshot(DownloadTaskSnapshot value) {
    snapshot = value;
  }
}

class _DownloadGroup {
  _DownloadGroup({
    required this.id,
    required this.jobIds,
    required this.submission,
  });

  final String id;
  final List<String> jobIds;
  final DownloadSubmissionSnapshot submission;
}

class DownloadOwnershipException implements Exception {
  const DownloadOwnershipException(this.message);

  final String message;

  @override
  String toString() => 'DownloadOwnershipException: $message';
}

class DownloadStorageException implements Exception {
  const DownloadStorageException(this.message);

  final String message;
}

class DownloadPermissionException implements Exception {
  const DownloadPermissionException(this.message);

  final String message;
}

class DownloadDecodeException implements Exception {
  const DownloadDecodeException(this.message);

  final String message;
}

class DownloadResourceLimitException implements Exception {
  const DownloadResourceLimitException(this.message);

  final String message;
}

DownloadFailureKind classifyDownloadFailure(Object error) {
  if (error is DownloadCancelledException) return DownloadFailureKind.canceled;
  if (error is DownloadOwnershipException) return DownloadFailureKind.ownership;
  if (error is DownloadHttpStatusException) {
    return switch (error.statusCode) {
      401 || 403 => DownloadFailureKind.auth,
      408 || 425 || 500 || 502 || 503 || 504 => DownloadFailureKind.network,
      413 => DownloadFailureKind.resource,
      429 => DownloadFailureKind.rateLimit,
      507 => DownloadFailureKind.storage,
      _ => DownloadFailureKind.unknown,
    };
  }
  if (error is DownloadStorageException || error is FileSystemException) {
    return DownloadFailureKind.storage;
  }
  if (error is DownloadPermissionException ||
      error.toString().toLowerCase().contains('permission')) {
    return DownloadFailureKind.permission;
  }
  if (error is DownloadDecodeException || error is FormatException) {
    return DownloadFailureKind.decode;
  }
  if (error is DownloadResourceLimitException ||
      error.toString().toLowerCase().contains('out of memory') ||
      error.toString().toLowerCase().contains('limit exceeded')) {
    return DownloadFailureKind.resource;
  }
  if (error is NetworkFailureException ||
      error is DownloadTransportException ||
      error is SocketException) {
    return DownloadFailureKind.network;
  }
  return DownloadFailureKind.unknown;
}

String _safeError(Object error) {
  if (error is DownloadHttpStatusException) {
    return 'HTTP ${error.statusCode} download failure';
  }
  return error.toString();
}

Duration? _retryAfter(DownloadResponse response) {
  if (response is! DownloadResponseMetadata) return null;
  return _parseRetryAfter((response as DownloadResponseMetadata).headers);
}

Duration? _retryAfterFromError(Object error) {
  if (error is DownloadHttpStatusException) return error.retryAfter;
  return null;
}

Duration? _parseRetryAfter(Map<String, String> headers) {
  String? value;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'retry-after') {
      value = entry.value.trim();
      break;
    }
  }
  if (value == null || value.isEmpty) return null;
  final seconds = int.tryParse(value);
  if (seconds != null && seconds >= 0 && seconds <= 86400) {
    return Duration(seconds: seconds);
  }
  final date = DateTime.tryParse(value);
  if (date == null) return null;
  final delta = date.toUtc().difference(DateTime.now().toUtc());
  return delta.isNegative ? Duration.zero : delta;
}
