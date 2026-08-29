import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_request.dart';

/// Lifecycle states persisted for one download attempt.
///
/// `retryable` is deliberately non-terminal: it represents work that may be
/// retried only after the caller explicitly asks for it. `orphaned` is a
/// terminal state because its output owner can no longer be proven.
enum DownloadStatus {
  queued,
  running,
  finalizing,
  canceling,
  succeeded,
  failed,
  canceled,
  retryable,
  orphaned,
}

/// Stable failure categories shown to callers and diagnostics. The original
/// exception is kept only in the human-readable task error, never in the
/// persisted recovery record.
enum DownloadFailureKind {
  auth,
  rateLimit,
  network,
  storage,
  permission,
  decode,
  resource,
  canceled,
  ownership,
  unknown,
}

/// The account boundary captured when a request is accepted.
///
/// It contains no credential material. A null context is supported only for
/// legacy/unit callers; the app-scoped provider requires an owned context so
/// product downloads cannot be recovered across accounts.
@immutable
class DownloadSubmissionContext {
  const DownloadSubmissionContext({
    required this.accountId,
    required this.credentialRevision,
    this.destination = kDownloadDestination,
  });

  final String accountId;
  final int credentialRevision;
  final String destination;
}

const String kDownloadDestination = 'Pictures/PixivFunc';

/// Immutable submission identity carried through every download phase.
///
/// The request object is itself immutable; keeping it here means account,
/// target and destination values cannot be replaced by a later
/// settings/account change.
@immutable
class DownloadSubmissionSnapshot {
  const DownloadSubmissionSnapshot({
    required this.snapshotId,
    required this.jobId,
    required this.groupId,
    required this.request,
    required this.accountId,
    required this.credentialRevision,
    required this.submittedAt,
    this.destination = kDownloadDestination,
  });

  final String snapshotId;
  final String jobId;
  final String? groupId;
  final DownloadRequest request;
  final String? accountId;
  final int credentialRevision;
  final DateTime submittedAt;
  final String destination;

  int get illustId => request.illustId;
  int get pageIndex => request.pageIndex;
  Uri get sourceUrl => request.url;
  DownloadTarget get target => request.target;
  String get displayName => request.displayName;
  String get format => request.mimeType;
  bool get isOwned => accountId != null && accountId!.isNotEmpty;

  DownloadSubmissionSnapshot copyWith({
    String? jobId,
    Object? groupId = _sentinel,
  }) {
    return DownloadSubmissionSnapshot(
      snapshotId: snapshotId,
      jobId: jobId ?? this.jobId,
      groupId: identical(groupId, _sentinel)
          ? this.groupId
          : groupId as String?,
      request: request,
      accountId: accountId,
      credentialRevision: credentialRevision,
      submittedAt: submittedAt,
      destination: destination,
    );
  }

  static const _sentinel = Object();
}

/// Opaque ownership marker for temporary files and pending MediaStore rows.
///
/// A path is intentionally absent. Paths and content URIs stay inside the
/// sink/platform boundary; recovery persists only an owner marker and the
/// platform row id when available.
@immutable
class DownloadOutputOwner {
  const DownloadOutputOwner({
    required this.ownerId,
    required this.jobId,
    required this.accountId,
  });

  final String ownerId;
  final String jobId;
  final String? accountId;

  Map<String, Object?> toJson() => {
    'ownerId': ownerId,
    'jobId': jobId,
    if (accountId != null) 'accountId': accountId,
  };

  factory DownloadOutputOwner.fromJson(Map<String, dynamic> json) {
    return DownloadOutputOwner(
      ownerId: json['ownerId'] as String,
      jobId: json['jobId'] as String,
      accountId: json['accountId'] as String?,
    );
  }
}

/// Metadata-only durable record used to recover a process interruption.
@immutable
class DownloadRecoveryRecord {
  const DownloadRecoveryRecord({
    required this.jobId,
    required this.dedupeKey,
    required this.snapshot,
    required this.owner,
    required this.status,
    this.receivedBytes = 0,
    this.totalBytes,
    this.pendingMediaStoreId,
    this.finalUri,
    this.error,
    this.failureKind,
    this.retryAfter,
    this.unknownStatus = false,
  });

  final String jobId;
  final String dedupeKey;
  final DownloadSubmissionSnapshot snapshot;
  final DownloadOutputOwner owner;
  final DownloadStatus status;
  final int receivedBytes;
  final int? totalBytes;
  final int? pendingMediaStoreId;
  final String? finalUri;
  final String? error;
  final DownloadFailureKind? failureKind;
  final Duration? retryAfter;
  final bool unknownStatus;

  Map<String, Object?> toJson() => {
    'jobId': jobId,
    'dedupeKey': dedupeKey,
    'snapshot': {
      'snapshotId': snapshot.snapshotId,
      'jobId': snapshot.jobId,
      if (snapshot.groupId != null) 'groupId': snapshot.groupId,
      'illustId': snapshot.illustId,
      'pageIndex': snapshot.pageIndex,
      'url': snapshot.sourceUrl.toString(),
      'target': snapshot.target.name,
      'displayName': snapshot.displayName,
      'format': snapshot.format,
      'destination': snapshot.destination,
      if (snapshot.accountId != null) 'accountId': snapshot.accountId,
      'credentialRevision': snapshot.credentialRevision,
      'submittedAt': snapshot.submittedAt.toUtc().toIso8601String(),
    },
    'owner': owner.toJson(),
    'status': status.name,
    'receivedBytes': receivedBytes,
    if (totalBytes != null) 'totalBytes': totalBytes,
    if (pendingMediaStoreId != null) 'pendingMediaStoreId': pendingMediaStoreId,
    if (finalUri != null) 'finalUri': finalUri,
    if (error != null) 'error': error,
    if (failureKind != null) 'failureKind': failureKind!.name,
    if (retryAfter != null) 'retryAfterMs': retryAfter!.inMilliseconds,
    if (unknownStatus) 'unknownStatus': true,
  };

  factory DownloadRecoveryRecord.fromJson(Map<String, dynamic> json) {
    final rawSnapshot = json['snapshot'];
    if (rawSnapshot is! Map<String, dynamic>) {
      throw const DownloadRecoveryDataException('snapshot is not an object');
    }
    final targetName = rawSnapshot['target'];
    final target = DownloadTarget.values.firstWhere(
      (value) => value.name == targetName,
      orElse: () => throw const DownloadRecoveryDataException(
        'snapshot target is invalid',
      ),
    );
    final request = DownloadRequest(
      illustId: rawSnapshot['illustId'] as int,
      pageIndex: rawSnapshot['pageIndex'] as int,
      url: Uri.parse(rawSnapshot['url'] as String),
      target: target,
    );
    final statusName = json['status'];
    final status = DownloadStatus.values.where(
      (value) => value.name == statusName,
    );
    final unknownStatus = status.isEmpty || json['unknownStatus'] == true;
    final parsedStatus = unknownStatus ? DownloadStatus.orphaned : status.first;
    final rawFailure = json['failureKind'];
    final failures = DownloadFailureKind.values.where(
      (value) => value.name == rawFailure,
    );
    final submittedAt = DateTime.tryParse(rawSnapshot['submittedAt'] as String);
    if (submittedAt == null) {
      throw const DownloadRecoveryDataException('snapshot timestamp invalid');
    }
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: rawSnapshot['snapshotId'] as String,
      jobId: rawSnapshot['jobId'] as String,
      groupId: rawSnapshot['groupId'] as String?,
      request: request,
      accountId: rawSnapshot['accountId'] as String?,
      credentialRevision: rawSnapshot['credentialRevision'] as int,
      submittedAt: submittedAt,
      destination:
          rawSnapshot['destination'] as String? ?? kDownloadDestination,
    );
    return DownloadRecoveryRecord(
      jobId: json['jobId'] as String,
      dedupeKey: json['dedupeKey'] as String,
      snapshot: snapshot,
      owner: DownloadOutputOwner.fromJson(
        (json['owner'] as Map).cast<String, dynamic>(),
      ),
      status: parsedStatus,
      receivedBytes: json['receivedBytes'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int?,
      pendingMediaStoreId: json['pendingMediaStoreId'] as int?,
      finalUri: json['finalUri'] as String?,
      error: json['error'] as String?,
      failureKind: failures.isEmpty ? null : failures.first,
      retryAfter: json['retryAfterMs'] is int
          ? Duration(milliseconds: json['retryAfterMs'] as int)
          : null,
      unknownStatus: unknownStatus,
    );
  }
}

/// Result of a restart scan. The manager never auto-retries a recovered job.
@immutable
class DownloadRecoveryReport {
  const DownloadRecoveryReport({
    this.retryableJobIds = const [],
    this.orphanedJobIds = const [],
    this.orphanedPendingOutputIds = const [],
    this.restoredJobIds = const [],
    this.skippedJobIds = const [],
    this.cleanupFailedJobIds = const [],
    this.cleanupFailedPendingOutputIds = const [],
    this.error,
  });

  final List<String> retryableJobIds;
  final List<String> orphanedJobIds;
  final List<int> orphanedPendingOutputIds;
  final List<String> restoredJobIds;
  final List<String> skippedJobIds;
  final List<String> cleanupFailedJobIds;
  final List<int> cleanupFailedPendingOutputIds;
  final Object? error;
}

/// Store contract deliberately persists metadata only; credentials and
/// request headers never cross this boundary.
abstract interface class DownloadRecoveryStore {
  Future<List<DownloadRecoveryRecord>> load();

  Future<void> upsert(DownloadRecoveryRecord record);

  Future<void> remove(String jobId);
}

/// Deterministic store for unit/restart fixtures.
class MemoryDownloadRecoveryStore implements DownloadRecoveryStore {
  final Map<String, DownloadRecoveryRecord> _records = {};

  List<DownloadRecoveryRecord> get records =>
      List.unmodifiable(_records.values.toList(growable: false));

  @override
  Future<List<DownloadRecoveryRecord>> load() async => records;

  @override
  Future<void> upsert(DownloadRecoveryRecord record) async {
    _records[record.jobId] = record;
  }

  @override
  Future<void> remove(String jobId) async {
    _records.remove(jobId);
  }
}

/// Versioned preferences store for app process recovery. It is bounded so a
/// long-lived app cannot turn task history into an unbounded queue.
class PreferencesDownloadRecoveryStore implements DownloadRecoveryStore {
  PreferencesDownloadRecoveryStore({
    SharedPreferencesAsync? preferences,
    String storageKey = defaultStorageKey,
  }) : _preferences = preferences ?? SharedPreferencesAsync(),
       _storageKey = _validateStorageKey(storageKey);

  static const defaultStorageKey = 'pixivfunc.download.recovery.v1';
  static const _maxRecords = 128;

  final SharedPreferencesAsync _preferences;
  final String _storageKey;
  Future<void> _writeTail = Future<void>.value();
  var _loaded = false;

  @override
  Future<List<DownloadRecoveryRecord>> load() async {
    await _writeTail;
    await _ensureLoaded();
    return List.unmodifiable(_cache);
  }

  @override
  Future<void> upsert(DownloadRecoveryRecord record) => _enqueue(() async {
    await _ensureLoaded();
    final records = _read()
        .where((existing) => existing.jobId != record.jobId)
        .toList(growable: true);
    records.add(record);
    final first = records.length > _maxRecords
        ? records.length - _maxRecords
        : 0;
    await _preferences.setStringList(
      _storageKey,
      records
          .sublist(first)
          .map((value) => jsonEncode(value.toJson()))
          .toList(growable: false),
    );
    _cache
      ..clear()
      ..addAll(records.sublist(first));
  });

  @override
  Future<void> remove(String jobId) => _enqueue(() async {
    await _ensureLoaded();
    final records = _read()
        .where((record) => record.jobId != jobId)
        .map((record) => jsonEncode(record.toJson()))
        .toList(growable: false);
    if (records.isEmpty) {
      await _preferences.remove(_storageKey);
    } else {
      await _preferences.setStringList(_storageKey, records);
    }
    _cache.removeWhere((record) => record.jobId == jobId);
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeTail.then((_) => operation());
    _writeTail = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final records = await _readFromPreferences();
    _cache
      ..clear()
      ..addAll(records);
    _loaded = true;
  }

  Future<List<DownloadRecoveryRecord>> _readFromPreferences() async {
    final raw = await _preferences.getStringList(_storageKey);
    if (raw == null) return const [];
    return [
      for (final value in raw)
        DownloadRecoveryRecord.fromJson(
          (jsonDecode(value) as Map).cast<String, dynamic>(),
        ),
    ];
  }

  List<DownloadRecoveryRecord> _read() {
    // _read is called only from the serialized write queue. SharedPreferences
    // Async has no synchronous getter, so writes use the last loaded cache.
    final cache = _cache;
    return List<DownloadRecoveryRecord>.from(cache);
  }

  final List<DownloadRecoveryRecord> _cache = [];

  static String _validateStorageKey(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, 'storageKey', 'must not be empty');
    }
    return value;
  }
}

class DownloadRecoveryDataException implements Exception {
  const DownloadRecoveryDataException(this.message);

  final String message;

  @override
  String toString() => 'DownloadRecoveryDataException: $message';
}
