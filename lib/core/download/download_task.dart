import 'package:meta/meta.dart';

import 'download_recovery.dart';

export 'download_recovery.dart'
    show
        DownloadFailureKind,
        DownloadOutputOwner,
        DownloadRecoveryDataException,
        DownloadRecoveryRecord,
        DownloadRecoveryReport,
        DownloadRecoveryStore,
        DownloadStatus,
        DownloadSubmissionContext,
        DownloadSubmissionSnapshot,
        MemoryDownloadRecoveryStore,
        PreferencesDownloadRecoveryStore;

/// Terminal-state helper for the download lifecycle. `canceling` remains
/// observable while a running task unwinds; `retryable` waits for user action
/// and `orphaned` is terminal when ownership cannot be proven.
bool isTerminal(DownloadStatus status) => switch (status) {
  DownloadStatus.succeeded ||
  DownloadStatus.failed ||
  DownloadStatus.canceled ||
  DownloadStatus.orphaned => true,
  DownloadStatus.queued ||
  DownloadStatus.running ||
  DownloadStatus.finalizing ||
  DownloadStatus.canceling ||
  DownloadStatus.retryable => false,
};

/// Immutable snapshot handed to the UI (read-only view of one task).
@immutable
class DownloadTaskSnapshot {
  const DownloadTaskSnapshot({
    required this.id,
    required this.illustId,
    required this.pageIndex,
    required this.url,
    required this.target,
    required this.displayName,
    required this.status,
    this.receivedBytes = 0,
    this.totalBytes,
    this.error,
    this.failureKind,
    this.retryAfter,
    this.finalUri,
    this.submission,
    this.outputOwner,
  });

  final String id;
  final int illustId;
  final int pageIndex;
  final Uri url;
  final String target;
  final String displayName;
  final DownloadStatus status;
  final int receivedBytes;

  /// Null when the server sent no content-length (R5 未知长度).
  final int? totalBytes;
  final String? error;
  final DownloadFailureKind? failureKind;
  final Duration? retryAfter;
  final Uri? finalUri;

  /// Immutable account/target/destination/policy boundary captured at submit.
  final DownloadSubmissionSnapshot? submission;

  /// Opaque owner for temporary output and pending MediaStore state.
  final DownloadOutputOwner? outputOwner;

  String? get groupId => submission?.groupId;

  /// 0..1 when the total length is known, otherwise null.
  double? get progress {
    final total = totalBytes;
    if (total == null || total == 0) return null;
    if (receivedBytes >= total) return 1.0;
    return receivedBytes / total;
  }

  DownloadTaskSnapshot copyWith({
    DownloadStatus? status,
    int? receivedBytes,
    Object? totalBytes = _sentinel,
    Object? error = _sentinel,
    Object? failureKind = _sentinel,
    Object? retryAfter = _sentinel,
    Object? finalUri = _sentinel,
    Object? submission = _sentinel,
    Object? outputOwner = _sentinel,
  }) {
    return DownloadTaskSnapshot(
      id: id,
      illustId: illustId,
      pageIndex: pageIndex,
      url: url,
      target: target,
      displayName: displayName,
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: identical(totalBytes, _sentinel)
          ? this.totalBytes
          : totalBytes as int?,
      error: identical(error, _sentinel) ? this.error : error as String?,
      failureKind: identical(failureKind, _sentinel)
          ? this.failureKind
          : failureKind as DownloadFailureKind?,
      retryAfter: identical(retryAfter, _sentinel)
          ? this.retryAfter
          : retryAfter as Duration?,
      finalUri: identical(finalUri, _sentinel)
          ? this.finalUri
          : finalUri as Uri?,
      submission: identical(submission, _sentinel)
          ? this.submission
          : submission as DownloadSubmissionSnapshot?,
      outputOwner: identical(outputOwner, _sentinel)
          ? this.outputOwner
          : outputOwner as DownloadOutputOwner?,
    );
  }

  static const _sentinel = Object();
}

/// Single terminal event per task (R3). Emitted exactly once when a task
/// reaches `succeeded`, `failed` or `canceled`.
@immutable
class DownloadEvent {
  const DownloadEvent.succeeded(this.snapshot)
    : kind = DownloadEventKind.succeeded,
      error = null;

  const DownloadEvent.failed(this.snapshot, this.error)
    : kind = DownloadEventKind.failed;

  const DownloadEvent.canceled(this.snapshot)
    : kind = DownloadEventKind.canceled,
      error = null;

  const DownloadEvent.orphaned(this.snapshot, this.error)
    : kind = DownloadEventKind.orphaned;

  final DownloadEventKind kind;
  final DownloadTaskSnapshot snapshot;
  final String? error;
}

enum DownloadEventKind { succeeded, failed, canceled, orphaned }

enum DownloadGroupStatus {
  queued,
  running,
  finalizing,
  succeeded,
  failed,
  canceled,
  retryable,
  orphaned,
}

/// Read-only aggregate view for Download All/Ugoira-style submissions.
@immutable
class DownloadGroupSnapshot {
  const DownloadGroupSnapshot({
    required this.id,
    required this.jobIds,
    required this.submission,
    required this.status,
  });

  final String id;
  final List<String> jobIds;
  final DownloadSubmissionSnapshot submission;
  final DownloadGroupStatus status;
}
