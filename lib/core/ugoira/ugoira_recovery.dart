import 'package:meta/meta.dart';

import '../download/download_recovery.dart';
import '../download/download_sink.dart';
import '../platform/android_platform_interfaces.dart';

/// Separate durable namespace for Ugoira post-process records. Ugoira output
/// is not a normal URL download, so its records must never be consumed by the
/// ordinary DownloadManager retry path.
const kUgoiraRecoveryStorageKey = 'pixivfunc.ugoira.recovery.v1';
const kUgoiraOutputOwnerPrefix = 'ugoira-output-';

@immutable
class UgoiraRecoveryReport {
  const UgoiraRecoveryReport({
    this.orphanedJobIds = const [],
    this.restoredJobIds = const [],
    this.orphanedPendingOutputIds = const [],
    this.cleanupFailedJobIds = const [],
    this.cleanupFailedPendingOutputIds = const [],
    this.error,
  });

  final List<String> orphanedJobIds;
  final List<String> restoredJobIds;
  final List<int> orphanedPendingOutputIds;
  final List<String> cleanupFailedJobIds;
  final List<int> cleanupFailedPendingOutputIds;
  final Object? error;
}

/// Resolves Ugoira records left by a process interruption.
///
/// A GIF export cannot resume without its in-memory [UgoiraAsset], so active
/// records become explicitly [DownloadStatus.orphaned]. Known pending rows
/// are cleaned only through their exact owner marker; unknown rows remain
/// observable and untouched. No automatic post-process retry is attempted.
Future<UgoiraRecoveryReport> recoverUgoiraExports({
  required DownloadRecoveryStore store,
  required DownloadSinkFactory sinkFactory,
}) async {
  List<DownloadRecoveryRecord> records;
  try {
    records = await store.load();
  } on Object catch (error) {
    return UgoiraRecoveryReport(error: error);
  }

  if (sinkFactory is! RecoverableDownloadSinkFactory) {
    return UgoiraRecoveryReport(
      error: StateError('Ugoira pending output recovery is unsupported'),
    );
  }
  final recoverable = sinkFactory as RecoverableDownloadSinkFactory;
  List<PendingMediaStoreItem> pendingItems;
  try {
    pendingItems = await recoverable.listPending();
  } on Object catch (error) {
    return UgoiraRecoveryReport(error: error);
  }

  final pendingByOwner = <String, PendingMediaStoreItem>{};
  for (final item in pendingItems) {
    final ownerId = item.ownerId;
    if (ownerId != null) pendingByOwner[ownerId] = item;
  }
  final matchedPending = <int>{};
  final orphaned = <String>[];
  final restored = <String>[];
  final orphanedPending = <int>[];
  final cleanupFailed = <String>[];
  final cleanupFailedPending = <int>[];
  Object? recoveryError;

  for (final record in records) {
    final scanned = pendingByOwner[record.owner.ownerId];
    final pendingId = record.pendingMediaStoreId ?? scanned?.id;
    if (pendingId != null) matchedPending.add(pendingId);

    if (record.status == DownloadStatus.succeeded) {
      if (pendingId != null) orphanedPending.add(pendingId);
      restored.add(record.jobId);
      continue;
    }

    var cleanupOk = true;
    if (pendingId != null) {
      try {
        cleanupOk = await recoverable.cleanupPending(
          pendingId,
          owner: record.owner,
        );
      } on Object catch (error) {
        cleanupOk = false;
        recoveryError ??= error;
      }
      if (!cleanupOk) {
        cleanupFailed.add(record.jobId);
        cleanupFailedPending.add(pendingId);
      }
    }

    final active = switch (record.status) {
      DownloadStatus.queued ||
      DownloadStatus.running ||
      DownloadStatus.finalizing ||
      DownloadStatus.canceling ||
      DownloadStatus.retryable => true,
      DownloadStatus.failed ||
      DownloadStatus.canceled ||
      DownloadStatus.orphaned ||
      DownloadStatus.succeeded => false,
    };
    final nextStatus = active ? DownloadStatus.orphaned : record.status;
    final nextError = active
        ? 'process restarted before Ugoira export completed; explicit reload is required'
        : record.error;
    final nextPendingId = cleanupOk ? null : pendingId;
    final nextRecord = _copyRecord(
      record,
      status: nextStatus,
      pendingMediaStoreId: nextPendingId,
      error: nextError,
    );
    try {
      await store.upsert(nextRecord);
    } on Object catch (error) {
      recoveryError ??= error;
    }
    if (active) {
      orphaned.add(record.jobId);
    } else {
      restored.add(record.jobId);
    }
  }

  for (final item in pendingItems) {
    if (!matchedPending.contains(item.id) &&
        item.ownerId?.startsWith(kUgoiraOutputOwnerPrefix) == true) {
      orphanedPending.add(item.id);
    }
  }

  return UgoiraRecoveryReport(
    orphanedJobIds: List.unmodifiable(orphaned),
    restoredJobIds: List.unmodifiable(restored),
    orphanedPendingOutputIds: List.unmodifiable(orphanedPending),
    cleanupFailedJobIds: List.unmodifiable(cleanupFailed),
    cleanupFailedPendingOutputIds: List.unmodifiable(cleanupFailedPending),
    error: recoveryError,
  );
}

DownloadRecoveryRecord _copyRecord(
  DownloadRecoveryRecord record, {
  required DownloadStatus status,
  required int? pendingMediaStoreId,
  required String? error,
}) {
  return DownloadRecoveryRecord(
    jobId: record.jobId,
    dedupeKey: record.dedupeKey,
    snapshot: record.snapshot,
    owner: record.owner,
    status: status,
    receivedBytes: record.receivedBytes,
    totalBytes: record.totalBytes,
    pendingMediaStoreId: pendingMediaStoreId,
    finalUri: record.finalUri,
    error: error,
    failureKind: record.failureKind,
    retryAfter: record.retryAfter,
    unknownStatus: record.unknownStatus,
  );
}
