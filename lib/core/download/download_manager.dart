/// Typed download jobs, streaming sinks, progress, and durable recovery.
/// [DownloadManager] owns job lifecycle; platform sinks own final output.
/// See `frontend/state-management.md` and `backend/directory-structure.md`.
library;

import 'dart:async';
import 'dart:developer' show log;
import '../network/pixiv_headers.dart';
import 'dart:io';
import 'dart:math' show Random;

import '../network/compat/network_contracts.dart';
import '../network/compat/segmented_fetch.dart';
import '../platform/android_platform_interfaces.dart';
import 'download_destination.dart';
import 'download_request.dart';
import 'download_sink.dart';
import 'download_task.dart';
import 'download_transport.dart';
import 'pixiv_download_transport.dart';

/// Per-task progress snapshot emission interval (R5 throttle).
const Duration _kProgressThrottle = Duration(milliseconds: 200);

/// Below this many remaining bytes a download continues on one connection
/// after its first segment.
const int _kParallelMinRemaining = 2 << 20;

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
    this.progressThrottle = _kProgressThrottle,
    DownloadSubmissionContextProvider? submissionContext,
    DownloadRecoveryStore? recoveryStore,
    this.requireOwnedSubmissions = false,
    this.enforceDefaultDestination = true,
    this.cacheLookup,
    this.segmentBudget,
    DateTime Function()? now,
  }) : _transport = transport,
       _sinkFactory = sinkFactory,
       _maxConcurrent = maxConcurrent,
       _submissionContext = submissionContext,
       _recoveryStore = recoveryStore ?? MemoryDownloadRecoveryStore(),
       _now = now ?? DateTime.now;

  final DownloadTransport _transport;
  final DownloadSinkFactory _sinkFactory;

  /// Optional local lookup consulted before any transport request: an image
  /// already in the disk cache materializes straight into the sink without
  /// spending a network round-trip. Misses and lookup errors fall through
  /// to the transport — the lookup must never make a download worse.
  final Future<File?> Function(Uri url)? cacheLookup;

  /// Extra connections for fetching one file in parallel byte ranges,
  /// shared by the main isolate's transfers (the image worker keeps its
  /// own). Null keeps every download on a single connection.
  final SegmentBudget? segmentBudget;
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

  /// Sequence numbers restart with every process, while ids live on in the
  /// recovery store: a per-launch token keeps a new group or job from
  /// reusing the id of a recovered one (two downloads made in different
  /// launches once merged into one group).
  final String _launch = Random.secure().nextInt(1 << 32).toRadixString(36);
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
    ResumeAnchor? resumeAnchor,
  }) => _submit(
    request,
    groupId: groupId,
    context: context,
    resumeAnchor: resumeAnchor,
  );

  /// [frozenName] is the file name fixed at the original submission; [retry]
  /// passes it because a recovered request lacks the template inputs to
  /// recompute it (C8). A fresh submit computes the name from the request.
  DownloadTaskSnapshot _submit(
    DownloadRequest request, {
    String? frozenName,
    String? groupId,
    DownloadSubmissionContext? context,
    ResumeAnchor? resumeAnchor,
  }) {
    _checkUsable();
    validateDownloadUrl(request.url, target: request.target);
    final ownerContext = context ?? _submissionContext?.call();
    if (requireOwnedSubmissions && ownerContext == null) {
      throw const _DownloadOwnershipException(
        'an authenticated submission boundary is required',
      );
    }
    if (ownerContext != null &&
        (ownerContext.accountId.isEmpty ||
            (enforceDefaultDestination &&
                !ownerContext.destination.isBuiltin))) {
      throw const _DownloadOwnershipException(
        'submission destination or account owner is invalid',
      );
    }
    final key = _identityKey(request, ownerContext);
    final existing = _jobs[key];
    if (existing != null && !isTerminal(existing.snapshot.status)) {
      return existing.snapshot;
    }

    // A terminal attempt is replaced by the new submission. Preserve its
    // resumable output and frozen name so a retry-like fresh request can
    // continue the same bytes without leaving the old record in its group.
    final inheritedName = existing?.resumeAnchor == null
        ? null
        : existing!.displayName;
    final inheritedAnchor = existing?.resumeAnchor;
    if (existing != null) _retire(existing);
    final name = frozenName ?? inheritedName ?? request.displayName;
    validateDisplayName(name);

    final id =
        'download_${request.illustId}_${request.pageIndex}_${_launch}_$_nextSeq';
    _nextSeq++;
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission_$id',
      jobId: id,
      groupId: groupId,
      request: request,
      accountId: ownerContext?.accountId,
      submittedAt: _now().toUtc(),
      destination: ownerContext?.destination ?? DownloadDestination.builtin,
      displayName: name,
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
    // The anchor must be attached before _schedule() runs the job: _run
    // reads it synchronously before its first await (D8).
    job.resumeAnchor = resumeAnchor ?? inheritedAnchor;
    _jobs[key] = job;
    _notifyChange();
    _persist(job);
    _schedule();
    return job.snapshot;
  }

  /// Creates an explicit group for Download All and Ugoira-style multi-step
  /// work. All children capture one submission context before any dispatch.
  DownloadGroupSubmission submitGroup(
    List<DownloadRequest> requests, {
    DownloadSubmissionContext? context,
  }) {
    _checkUsable();
    if (requests.isEmpty) {
      throw ArgumentError('a download group must contain a request');
    }
    final resolvedGroupId = 'download_group_${_launch}_${_nextGroupSeq++}';
    final ownerContext = context ?? _submissionContext?.call();
    final children = [
      for (final request in requests)
        submit(request, groupId: resolvedGroupId, context: ownerContext),
    ];
    final newChildren = [
      for (final child in children)
        if (child.submission?.groupId == resolvedGroupId) child,
    ];
    if (newChildren.isEmpty) {
      return DownloadGroupSubmission(
        group: null,
        tasks: List.unmodifiable(children),
      );
    }
    final submission = newChildren.first.submission;
    if (submission == null) {
      throw StateError('new download group child has no submission snapshot');
    }
    _groups[resolvedGroupId] = _DownloadGroup(
      id: resolvedGroupId,
      jobIds: [for (final child in newChildren) child.id],
      submission: submission,
    );
    final result = DownloadGroupSubmission(
      group: _groupSnapshot(_groups[resolvedGroupId]!),
      tasks: List.unmodifiable(children),
    );
    _notifyChange();
    return result;
  }

  /// Pauses a queued or running task and preserves its written bytes when the
  /// sink supports resume (D8). A paused task lands in
  /// [DownloadStatus.retryable] — never `canceled` — and the next [retry]
  /// attempt may append via `Range`. Pause is distinct from [cancel], which
  /// still aborts and deletes partial output.
  Future<void> pause(String taskId) async {
    final job = _findById(taskId);
    if (job == null || isTerminal(job.snapshot.status)) return;
    switch (job.snapshot.status) {
      case DownloadStatus.queued:
        _transition(job, DownloadStatus.retryable);
        _update(
          job,
          job.snapshot.copyWith(
            error: 'download paused',
            failureKind: DownloadFailureKind.paused,
          ),
        );
      case DownloadStatus.running:
        job.pauseRequested = true;
        job.cancelToken.cancel();
      case DownloadStatus.canceling:
      case DownloadStatus.finalizing:
      // Unwinding/finalizing already has a committed outcome; a pause at
      // this point is a no-op rather than a second lifecycle.
      case DownloadStatus.retryable:
      case DownloadStatus.succeeded:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
      case DownloadStatus.orphaned:
        return;
    }
  }

  /// Cancels a queued/retryable task immediately or asks a running transfer
  /// to unwind. Once finalization has started, cancellation cannot make an
  /// already-visible output disappear; the finalization result wins.
  /// Cancellation deletes preserved partial output — it is not a pause.
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
    final anchor = job.resumeAnchor;
    final groupId = job.snapshot.groupId;
    _retire(job);
    final retried = _submit(
      job.request,
      frozenName: job.displayName,
      groupId: groupId,
      resumeAnchor: anchor,
    );
    if (groupId != null && retried.submission?.groupId == groupId) {
      final group = _groups[groupId] ??= _DownloadGroup(
        id: groupId,
        jobIds: [],
        submission: retried.submission!,
      );
      if (!group.jobIds.contains(retried.id)) group.jobIds.add(retried.id);
    }
    return retried;
  }

  /// Pauses every non-terminal child of a group (D8). Each child follows
  /// the same [pause] semantics: resumable outputs keep their anchor and
  /// land in `retryable`, never `canceled`.
  Future<void> pauseGroup(String groupId) async {
    final group = _groups[groupId];
    if (group == null) return;
    for (final id in List.of(group.jobIds)) {
      await pause(id);
    }
  }

  /// Retries every failed/canceled/retryable child of a group. Running and
  /// succeeded children are left alone — [retry] rejects them already.
  void resumeGroup(String groupId) {
    final group = _groups[groupId];
    if (group == null) return;
    // retry() replaces the child id inside group.jobIds — iterate a copy.
    for (final id in List.of(group.jobIds)) {
      retry(id);
    }
  }

  /// Cancels every non-terminal child of a group. Cancellation still
  /// deletes preserved partial output — it is not a pause.
  Future<void> cancelGroup(String groupId) async {
    final group = _groups[groupId];
    if (group == null) return;
    for (final id in List.of(group.jobIds)) {
      await cancel(id);
    }
  }

  /// Removes the terminal tasks among [taskIds] from the list along with
  /// their durable records. In-flight work is not history — non-terminal and
  /// unknown ids are skipped; [cancel] must land first. Preserved output and
  /// finished files stay on disk, so [restore] can put the records back.
  DownloadRemoval dismissAll(Iterable<String> taskIds) {
    final targets = <_Job>[
      for (final id in taskIds.toSet())
        if (_findById(id) case final job? when isTerminal(job.snapshot.status))
          job,
    ];
    if (targets.isEmpty) return const DownloadRemoval._([]);
    // Positions are read before anything moves, so restore can replay them
    // in ascending order.
    final jobIndex = {for (final (i, key) in _jobs.keys.indexed) key: i};
    final groupIndex = {for (final (i, id) in _groups.keys.indexed) id: i};
    final removed = [
      for (final job in targets)
        _RemovedJob(
          job: job,
          index: jobIndex[job.key]!,
          group: switch (_groups[job.snapshot.groupId]) {
            null => null,
            final group => (
              id: group.id,
              submission: group.submission,
              index: groupIndex[group.id]!,
              position: group.jobIds.indexOf(job.id),
            ),
          },
        ),
    ];
    for (final entry in removed) {
      _retire(entry.job);
    }
    _notifyChange();
    return DownloadRemoval._(removed);
  }

  /// Puts back what [dismissAll] removed: each task at its old place in the
  /// list and in its own group, its record written again. A task whose
  /// identity was submitted anew meanwhile stays removed — the new task
  /// owns it. A group that went away (with these tasks or with a later
  /// removal) comes back at its old place, holding only restored tasks.
  /// After a restart restored records follow the store's order.
  void restore(DownloadRemoval removal) {
    if (_disposed || removal.isEmpty) return;
    final restored = [
      for (final removed in removal._jobs)
        if (!_jobs.containsKey(removed.job.key)) removed,
    ];
    if (restored.isEmpty) return;
    _insertInOrder(_jobs, [
      for (final removed in restored)
        (removed.index, MapEntry(removed.job.key, removed.job)),
    ]);
    final missingGroups = {
      for (final removed in restored)
        if (removed.group case final group? when !_groups.containsKey(group.id))
          group.id: group,
    };
    _insertInOrder(_groups, [
      for (final group in missingGroups.values)
        (
          group.index,
          MapEntry(
            group.id,
            _DownloadGroup(
              id: group.id,
              jobIds: [],
              submission: group.submission,
            ),
          ),
        ),
    ]);
    final grouped = [
      for (final removed in restored)
        if (removed.group != null) removed,
    ]..sort((a, b) => a.group!.position.compareTo(b.group!.position));
    for (final removed in grouped) {
      final jobIds = _groups[removed.group!.id]!.jobIds;
      jobIds.insert(
        removed.group!.position.clamp(0, jobIds.length),
        removed.job.id,
      );
    }
    for (final removed in restored) {
      _persist(removed.job);
    }
    _notifyChange();
  }

  /// Inserts [items] into [map] at their old indexes. Replayed in ascending
  /// order, each lands where it was as long as nothing else moved.
  static void _insertInOrder<V>(
    Map<String, V> map,
    List<(int, MapEntry<String, V>)> items,
  ) {
    if (items.isEmpty) return;
    final entries = map.entries.toList();
    for (final (index, entry) in [
      ...items,
    ]..sort((a, b) => a.$1.compareTo(b.$1))) {
      entries.insert(index.clamp(0, entries.length), entry);
    }
    map
      ..clear()
      ..addEntries(entries);
  }

  /// Removes a task from its lookup map, group membership and durable store.
  /// Preserved output is intentionally left untouched so a replacement can
  /// take ownership of its resume anchor; unowned output remains observable
  /// to the existing recovery scan.
  void _retire(_Job job) {
    _jobs.remove(job.key);
    final groupId = job.snapshot.groupId;
    final group = groupId == null ? null : _groups[groupId];
    if (group != null) {
      group.jobIds.remove(job.id);
      if (group.jobIds.isEmpty) _groups.remove(groupId);
    }
    _persistRemove(job.id);
  }

  /// Scans durable metadata after process start. Only a complete record whose
  /// account and destination still match the current context becomes
  /// [DownloadStatus.retryable]. Recovery
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
    List<DownloadRecoveryRecord> loadedRecords;
    try {
      loadedRecords = await _recoveryStore.load();
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
    final supersededJobIds = <String>[];

    // A crash or an upgrade can leave more than one durable attempt for the
    // same identity. Keep the newest submission and retire older records
    // before rebuilding jobs or groups, so stale groups cannot reappear.
    final latestByDedupeKey = <String, DownloadRecoveryRecord>{};
    for (final record in loadedRecords) {
      final current = latestByDedupeKey[record.dedupeKey];
      if (current == null ||
          !record.snapshot.submittedAt.isBefore(current.snapshot.submittedAt)) {
        latestByDedupeKey[record.dedupeKey] = record;
      }
    }
    final records = <DownloadRecoveryRecord>[];
    for (final record in loadedRecords) {
      if (identical(latestByDedupeKey[record.dedupeKey], record)) {
        records.add(record);
        continue;
      }
      final scannedPending = pendingByOwner[record.owner.ownerId];
      final pendingId = record.pendingMediaStoreId ?? scannedPending?.id;
      if (pendingId != null) matchedPending.add(pendingId);
      var cleanupOk = true;
      if (pendingId != null &&
          record.status != DownloadStatus.succeeded &&
          record.resumeAnchor == null) {
        cleanupOk = await _cleanupPendingOutput(pendingId, record.owner);
        if (!cleanupOk) {
          cleanupFailed.add(record.jobId);
          cleanupFailedPending.add(pendingId);
        }
      }
      if (record.status == DownloadStatus.succeeded && pendingId != null) {
        orphanedPending.add(pendingId);
      }
      _persistRemove(record.jobId);
      supersededJobIds.add(record.jobId);
    }
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
      // A record carrying a resume anchor keeps its pending row on purpose:
      // the row IS the resume payload (D8), not interrupted output to clean.
      if (pendingId != null &&
          record.status != DownloadStatus.succeeded &&
          record.resumeAnchor == null) {
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
        validateDisplayName(record.snapshot.displayName);
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
      supersededJobIds: supersededJobIds,
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
        : '${context.accountId}|${context.destination.identity}';
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
    var resumeOffset = 0;
    try {
      _checkOwner(job);
      final anchor = job.resumeAnchor;
      if (anchor != null) {
        sink = await _resumeSink(job, anchor);
        if (sink != null) {
          resumeOffset = anchor.storedBytes;
        }
      }
      sink ??= await _beginSink(job);
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      if (sink is DownloadSinkOutputMetadata) {
        job.pendingOutputId =
            (sink as DownloadSinkOutputMetadata).pendingOutputId;
        _persist(job);
      }
      _checkOwner(job);
      var openedResponse = await _open(job, resumeOffset);
      response = openedResponse;
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      if (resumeOffset > 0 &&
          (openedResponse.statusCode == 200 ||
              openedResponse.statusCode == 416)) {
        // The server ignored or rejected the Range request: appending its
        // full body would corrupt the preserved bytes, so the stale output
        // is discarded and the transfer restarts clean (D8).
        await closeResponse();
        await _discardSink(sink);
        sink = null;
        resumeOffset = 0;
        job.resumeAnchor = null;
        _persist(job);
        sink = await _beginSink(job);
        if (job.cancelToken.isCancelled) {
          throw const DownloadCancelledException();
        }
        if (sink is DownloadSinkOutputMetadata) {
          job.pendingOutputId =
              (sink as DownloadSinkOutputMetadata).pendingOutputId;
          _persist(job);
        }
        openedResponse = await _open(job, 0);
        response = openedResponse;
        if (job.cancelToken.isCancelled) {
          throw const DownloadCancelledException();
        }
      }
      if (openedResponse.statusCode < 200 || openedResponse.statusCode >= 300) {
        throw DownloadHttpStatusException(
          openedResponse.statusCode,
          job.request.url,
          retryAfter: _retryAfter(openedResponse),
        );
      }
      await _streamAndFinalize(
        job,
        sink,
        openedResponse,
        closeResponse,
        resumeOffset: resumeOffset,
      );
    } on DownloadCancelledException {
      await _handleCancellation(job, sink, closeResponse);
    } on _DownloadOwnershipException catch (error) {
      await _handleOwnershipFailure(job, sink, closeResponse, error);
    } catch (error) {
      await _handleGenericFailure(job, sink, closeResponse, error);
    } finally {
      if (!responseClosed) await closeResponse();
      _schedule();
    }
  }

  Future<void> _streamAndFinalize(
    _Job job,
    DownloadSink sink,
    DownloadResponse response,
    Future<void> Function() closeResponse, {
    int resumeOffset = 0,
  }) async {
    _checkOwner(job);
    final contentLength = response.contentLength;
    _update(
      job,
      job.snapshot.copyWith(
        // A 206 body carries only the remaining bytes; the task's total and
        // received counts stay measured against the whole file (D8).
        totalBytes: contentLength == null ? null : resumeOffset + contentLength,
        receivedBytes: resumeOffset,
      ),
    );

    var received = resumeOffset;
    // Parallel ranges arrive ahead of the in-order bytes the sink takes;
    // counting only the sink would make progress jump a segment at a time.
    final segmented = response is _SegmentedDownloadResponse ? response : null;
    var lastEmit = _now();
    await for (final chunk in response.stream) {
      if (job.cancelToken.isCancelled) {
        throw const DownloadCancelledException();
      }
      _checkOwner(job);
      await sink.write(chunk);
      received += chunk.length;
      final now = _now();
      if (now.difference(lastEmit) >= progressThrottle) {
        lastEmit = now;
        final shown = segmented == null
            ? received
            : resumeOffset + segmented.fetchedBytes;
        _update(job, job.snapshot.copyWith(receivedBytes: shown));
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
    job.resumeAnchor = null;
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
  }

  Future<void> _handleCancellation(
    _Job job,
    DownloadSink? sink,
    Future<void> Function() closeResponse,
  ) async {
    await _finishOutput(job, sink, preserve: job.pauseRequested);
    await closeResponse();
    if (job.pauseRequested && !job.ownerInvalidated) {
      _finishPause(job);
    } else {
      _completeCancellation(job, orphaned: job.ownerInvalidated);
    }
  }

  void _finishPause(_Job job) {
    _transition(job, DownloadStatus.retryable);
    _update(
      job,
      job.snapshot.copyWith(
        error: 'download paused',
        failureKind: DownloadFailureKind.paused,
      ),
    );
  }

  void _completeCancellation(_Job job, {bool orphaned = false}) {
    if (orphaned) {
      _transition(job, DownloadStatus.orphaned);
      _update(
        job,
        job.snapshot.copyWith(
          error: 'download owner changed while task was active',
          failureKind: DownloadFailureKind.ownership,
        ),
      );
      _complete(job, DownloadEvent.orphaned(job.snapshot, job.snapshot.error));
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
  }

  Future<void> _handleOwnershipFailure(
    _Job job,
    DownloadSink? sink,
    Future<void> Function() closeResponse,
    _DownloadOwnershipException error,
  ) async {
    await _finishOutput(job, sink, preserve: false);
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
  }

  Future<void> _handleGenericFailure(
    _Job job,
    DownloadSink? sink,
    Future<void> Function() closeResponse,
    Object error,
  ) async {
    final failureKind = _classifyDownloadFailure(error);
    // Some transports surface socket teardown as a generic transport
    // error instead of DownloadCancelledException. Once cancellation has
    // been requested before finalization, the user/owner boundary still
    // wins over that secondary teardown error.
    final cancelled =
        job.cancelToken.isCancelled &&
        job.snapshot.status != DownloadStatus.finalizing;
    // Network failures preserve bytes for a byte-level resume (D8); every
    // other failure class keeps the abort-and-delete semantics.
    await _finishOutput(
      job,
      sink,
      preserve: cancelled
          ? job.pauseRequested
          : failureKind == DownloadFailureKind.network,
    );
    await closeResponse();
    if (cancelled) {
      if (job.pauseRequested && !job.ownerInvalidated) {
        _finishPause(job);
      } else {
        _completeCancellation(job, orphaned: job.ownerInvalidated);
      }
    } else {
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
  }

  Future<DownloadSink> _beginSink(_Job job) {
    final factory = _sinkFactory;
    if (factory is OwnedDownloadSinkFactory) {
      return (factory as OwnedDownloadSinkFactory).beginOwned(
        job.request,
        job.displayName,
        job.owner,
        destination: job.submission.destination,
      );
    }
    return factory.begin(
      job.request,
      job.displayName,
      destination: job.submission.destination,
    );
  }

  /// Reopens a preserved partial output for appending (D8). Returns null —
  /// meaning the caller must begin fresh — when the factory cannot resume,
  /// the platform output vanished, or the platform byte count disagrees
  /// with the durable record (the anchor is stale and gets discarded).
  Future<DownloadSink?> _resumeSink(_Job job, ResumeAnchor anchor) async {
    final factory = _sinkFactory;
    if (factory is! ResumableDownloadSinkFactory) {
      job.resumeAnchor = null;
      return null;
    }
    DownloadSink? sink;
    try {
      sink = await (factory as ResumableDownloadSinkFactory).resumeOwned(
        anchor,
        job.owner,
      );
    } on Object catch (error) {
      _lastRecoveryError = error;
      job.resumeAnchor = null;
      return null;
    }
    if (sink is! ResumableDownloadSink ||
        sink.storedBytes != anchor.storedBytes) {
      // The preserved byte count cannot be proven against the durable
      // record — appending would corrupt the output. Discard the anchor
      // and fall through to a fresh begin; this is a graceful downgrade,
      // not an error path.
      await _discardSink(sink);
      job.resumeAnchor = null;
      return null;
    }
    return sink;
  }

  Future<DownloadResponse> _open(_Job job, int resumeOffset) async {
    final lookup = cacheLookup;
    if (lookup != null) {
      try {
        final cached = await lookup(job.request.url);
        if (cached != null && await cached.exists()) {
          // A resume anchor means the sink already holds the head of this
          // file; the cached copy supplies only the missing tail so the
          // byte accounting stays identical to a 206 continuation.
          return await _FileDownloadResponse.open(cached, resumeOffset);
        }
      } on Object catch (error) {
        // Cache lookup is best-effort — a corrupt store or an unavailable
        // image worker never blocks the network path.
        log('DownloadManager cache lookup failed: $error');
      }
    }
    final headers = PixivHeaders.image(userAgent: true);
    final budget = segmentBudget;
    if (budget != null) {
      return _openSegmented(job, resumeOffset, headers, budget);
    }
    if (resumeOffset > 0) {
      headers['Range'] = 'bytes=$resumeOffset-';
    }
    return _transport.open(
      job.request.url,
      headers: headers,
      cancelToken: job.cancelToken,
    );
  }

  /// Asks for one segment from [resumeOffset]. A sized 206 continues in
  /// parallel ranges; any other status goes back to [_run] unchanged, so a
  /// server ignoring `Range` (200) or rejecting it (416) keeps its existing
  /// handling.
  Future<DownloadResponse> _openSegmented(
    _Job job,
    int resumeOffset,
    Map<String, String> headers,
    SegmentBudget budget,
  ) async {
    final url = job.request.url;
    final lastByte = resumeOffset + SegmentedFetch.defaultSegmentBytes - 1;
    final first = await _transport.open(
      url,
      headers: {...headers, 'Range': 'bytes=$resumeOffset-$lastByte'},
      cancelToken: job.cancelToken,
    );
    if (first.statusCode != 206) return first;
    final firstRange = _rangeResponse(first);
    final range = firstRange.contentRange;
    final total = range?.total;
    if (range == null || total == null || range.start != resumeOffset) {
      // Without the file size, or from another offset, these bytes cannot
      // be continued or appended.
      await firstRange.close().catchError((Object _) {});
      throw SegmentedFetchMismatch(
        'asked bytes=$resumeOffset-$lastByte, got '
        '${firstRange.headers['content-range']}',
      );
    }
    final remaining = total - resumeOffset;
    final fetch = SegmentedFetch(
      open: (start, end, {ifRange, required cancel}) => _openRange(
        url,
        headers,
        start,
        end,
        ifRange: ifRange,
        cancel: cancel,
      ),
      budget: budget,
      maxParallel: remaining >= _kParallelMinRemaining
          ? SegmentedFetch.defaultParallel
          : 1,
    );
    return _SegmentedDownloadResponse(
      fetch,
      firstRange,
      contentLength: remaining,
      cancel: job.cancelToken,
    );
  }

  /// One further segment on its own connection, closed through [cancel].
  Future<RangeResponse> _openRange(
    Uri url,
    Map<String, String> headers,
    int start,
    int end, {
    String? ifRange,
    required NetworkCancelSignal cancel,
  }) async {
    final token = DownloadCancelToken();
    unawaited(cancel.whenCancel.then((_) => token.cancel()));
    final response = await _transport.open(
      url,
      headers: {...headers, 'Range': 'bytes=$start-$end', 'If-Range': ?ifRange},
      cancelToken: token,
    );
    return _rangeResponse(response);
  }

  void _checkOwner(_Job job) {
    final snapshot = job.submission;
    if (!snapshot.isOwned || _submissionContext == null) return;
    final current = _submissionContext();
    if (current == null || !_sameContext(snapshot, current)) {
      job.ownerInvalidated = true;
      throw const _DownloadOwnershipException(
        'submission owner changed before output write/finalize',
      );
    }
  }

  bool _sameContext(
    DownloadSubmissionSnapshot snapshot,
    DownloadSubmissionContext context,
  ) {
    // C4: only the stable owner identity (account + destination) matters;
    // a token refresh inside the account never orphans a legitimate task.
    return snapshot.accountId == context.accountId &&
        snapshot.destination.identity == context.destination.identity;
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
      resumeAnchor: job.resumeAnchor,
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
      resumeAnchor: record.resumeAnchor,
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
    job.resumeAnchor = record.resumeAnchor;
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
            to == DownloadStatus.retryable ||
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
    // The mutable job field is the source of truth for the resume anchor;
    // every snapshot mirrors it so the UI cannot observe a stale token.
    job.applySnapshot(snapshot.copyWith(resumeAnchor: job.resumeAnchor));
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

  /// Ends the sink once: preserves written bytes as a [ResumeAnchor] when
  /// [preserve] is set and the sink supports detach (D8), otherwise aborts
  /// and deletes exactly like the legacy path.
  Future<void> _finishOutput(
    _Job job,
    DownloadSink? sink, {
    required bool preserve,
  }) async {
    if (job.cleanupStarted) return;
    job.cleanupStarted = true;
    if (preserve && sink is ResumableDownloadSink) {
      try {
        final anchor = await sink.detach();
        if (anchor != null) {
          job.resumeAnchor = anchor;
          _persist(job);
          return;
        }
      } catch (_) {
        // Detach failure must not mask the original task result; fall
        // through to abort so half-written output is not kept blindly.
      }
    }
    await _discardSink(sink);
  }

  Future<void> _discardSink(DownloadSink? sink) async {
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
    final children = [
      for (final id in group.jobIds) _findById(id)?.snapshot,
    ].whereType<DownloadTaskSnapshot>().toList(growable: false);
    assert(children.isNotEmpty, 'download groups must contain a task');
    final childStatuses = [for (final child in children) child.status];
    var receivedBytes = 0;
    var totalBytes = 0;
    var totalsKnown = children.isNotEmpty;
    var succeededCount = 0;
    for (final child in children) {
      receivedBytes += child.receivedBytes;
      final total = child.totalBytes;
      if (total == null) {
        totalsKnown = false;
      } else {
        totalBytes += total;
      }
      if (child.status == DownloadStatus.succeeded) succeededCount++;
    }
    return DownloadGroupSnapshot(
      id: group.id,
      jobIds: List.unmodifiable(group.jobIds),
      submission: group.submission,
      status: _aggregateGroupStatus(childStatuses),
      childCount: children.length,
      succeededCount: succeededCount,
      receivedBytes: receivedBytes,
      totalBytes: totalsKnown ? totalBytes : null,
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
        // Disposal prefers preserving resumable bytes: if the transport
        // unwinds cooperatively before teardown, the detach path persists a
        // resume anchor for the next process (D8).
        job.pauseRequested = true;
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

  /// Durable token for preserved partial output (D8); mirrored into every
  /// snapshot via [_update] so the UI sees the same value the record has.
  ResumeAnchor? resumeAnchor;

  /// A pause was requested; the next cancellation unwind preserves bytes
  /// and lands in `retryable` instead of `canceled`.
  var pauseRequested = false;

  void applySnapshot(DownloadTaskSnapshot value) {
    snapshot = value;
  }
}

/// What [DownloadManager.dismissAll] removed, kept so
/// [DownloadManager.restore] can put it back. Opaque outside the manager.
final class DownloadRemoval {
  const DownloadRemoval._(this._jobs);

  final List<_RemovedJob> _jobs;

  /// Ids of the tasks that were removed.
  List<String> get taskIds => [for (final removed in _jobs) removed.job.id];

  int get count => _jobs.length;
  bool get isEmpty => _jobs.isEmpty;
}

/// A removed task and where it sat: its index in the task list and, for a
/// group child, its group (enough to bring the group back), the group's
/// index among groups and the task's position in it.
final class _RemovedJob {
  const _RemovedJob({
    required this.job,
    required this.index,
    required this.group,
  });

  final _Job job;
  final int index;
  final ({
    String id,
    DownloadSubmissionSnapshot submission,
    int index,
    int position,
  })?
  group;
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

class _DownloadOwnershipException implements Exception {
  const _DownloadOwnershipException(this.message);

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

DownloadFailureKind _classifyDownloadFailure(Object error) {
  if (error is DownloadCancelledException) return DownloadFailureKind.canceled;
  if (error is _DownloadOwnershipException) {
    return DownloadFailureKind.ownership;
  }
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

RangeResponse _rangeResponse(DownloadResponse response) => RangeResponse(
  statusCode: response.statusCode,
  headers: switch (response) {
    final DownloadResponseMetadata metadata => {
      for (final entry in metadata.headers.entries)
        entry.key.toLowerCase(): entry.value,
    },
    _ => const {},
  },
  body: response.stream,
  close: response.close,
);

/// A sized 206 continued in parallel ranges. It reads like one 206 for the
/// rest of the file: [contentLength] counts from the resume offset to the
/// end and [headers] are the first segment's.
class _SegmentedDownloadResponse
    implements DownloadResponse, DownloadResponseMetadata {
  _SegmentedDownloadResponse(
    this._fetch,
    RangeResponse first, {
    required this.contentLength,
    required NetworkCancelSignal cancel,
  }) : headers = first.headers,
       stream = _fetch
           .continueFrom(first, cancel: cancel)
           .handleError(
             (Object _) => throw const DownloadCancelledException(),
             test: (error) => error is SegmentedFetchCancelled,
           );

  final SegmentedFetch _fetch;

  @override
  int get statusCode => 206;

  @override
  final int contentLength;

  @override
  final Map<String, String> headers;

  @override
  final Stream<List<int>> stream;

  /// Bytes received so far, including segments not yet in the sink.
  int get fetchedBytes => _fetch.fetchedBytes;

  @override
  Future<void> close() async => _fetch.close();
}

/// A download response served from a file already in the image disk cache.
/// `offset` mirrors an HTTP Range continuation: the stream yields only the
/// bytes the resumed sink is missing, and [contentLength] reports the tail
/// length so total/received accounting matches the transport path.
class _FileDownloadResponse implements DownloadResponse {
  _FileDownloadResponse(this._file, this._offset);

  final File _file;
  final int _offset;

  @override
  int get statusCode => 200;

  int? _contentLength;

  @override
  int? get contentLength => _contentLength;

  @override
  Stream<List<int>> get stream => _file.openRead(_offset);

  /// Resolves the tail length lazily is not possible here — the manager
  /// reads [contentLength] before listening, so length is captured eagerly
  /// by [open].
  static Future<_FileDownloadResponse> open(File file, int offset) async {
    final length = await file.length();
    final clamped = offset.clamp(0, length);
    return _FileDownloadResponse(file, clamped)
      .._contentLength = length - clamped;
  }

  @override
  Future<void> close() async {}
}
