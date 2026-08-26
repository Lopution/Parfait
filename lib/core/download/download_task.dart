import 'package:meta/meta.dart';

/// Task lifecycle. `canceling` is observable while a running task unwinds;
/// the transition set below is irreversible per task attempt.
enum DownloadStatus { queued, running, canceling, succeeded, failed, canceled }

bool isTerminal(DownloadStatus status) =>
    status == DownloadStatus.succeeded ||
    status == DownloadStatus.failed ||
    status == DownloadStatus.canceled;

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
    String? error,
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
      error: error ?? this.error,
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

  final DownloadEventKind kind;
  final DownloadTaskSnapshot snapshot;
  final String? error;
}

enum DownloadEventKind { succeeded, failed, canceled }
