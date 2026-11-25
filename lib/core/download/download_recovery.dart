import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/preference_keys.dart';

import 'download_destination.dart';
import 'naming_rule.dart';
import 'download_request.dart';
import 'download_subfolders.dart';
import 'resume_anchor.dart';

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

  /// The disk is full.
  noSpace,
  permission,

  /// The chosen folder, or the app's grant to it, is gone: it has to be
  /// picked again.
  destination,
  decode,
  resource,
  canceled,
  ownership,
  unknown,

  /// User paused the transfer; preserved bytes remain resumable.
  paused,
}

/// The account boundary captured when a request is accepted.
///
/// It contains no credential material. A null context is supported only for
/// legacy/unit callers; the app-scoped provider requires an owned context so
/// product downloads cannot be recovered across accounts.
///
/// C4: the owner is the stable `accountId + job/output + destination`; a
/// token refresh or a profile metadata update never
/// changes ownership. The destination is the D5 value object, persisted by
/// its canonical [DownloadDestination.identity] only.
@immutable
class DownloadSubmissionContext {
  const DownloadSubmissionContext({
    required this.accountId,
    this.destination = DownloadDestination.builtin,
  });

  final String accountId;
  final DownloadDestination destination;
}

/// Immutable submission identity carried through every download phase.
///
/// The request object is itself immutable; keeping it here means account,
/// target and destination values cannot be replaced by a later
/// settings/account change.
@immutable
class DownloadSubmissionSnapshot {
  DownloadSubmissionSnapshot({
    required this.snapshotId,
    required this.jobId,
    required this.groupId,
    required this.request,
    required this.accountId,
    required this.submittedAt,
    this.destination = DownloadDestination.builtin,
    String? displayName,
    List<String>? subdirectories,
  }) : displayName = displayName ?? request.displayName,
       subdirectories = List<String>.unmodifiable(
         subdirectories ?? request.subdirectories,
       ) {
    validateSubdirectories(this.subdirectories);
  }

  final String snapshotId;
  final String jobId;
  final String? groupId;
  final DownloadRequest request;
  final String? accountId;
  final DateTime submittedAt;
  final DownloadDestination destination;

  /// The file name fixed at submission time (C8): template inputs such as
  /// `{author_id}`/`{w}`/`{h}` are not persisted, so recomputing after a
  /// recovery would render empty segments. Serialization reads this field;
  /// recovery passes the stored value back through the constructor.
  final String displayName;

  /// Relative subdirectories fixed at submission time so retries and
  /// recovery write to the same subfolder hierarchy.
  final List<String> subdirectories;

  int get illustId => request.illustId;
  int get pageIndex => request.pageIndex;
  Uri get sourceUrl => request.url;
  DownloadTarget get target => request.target;
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
      submittedAt: submittedAt,
      destination: destination,
      displayName: displayName,
      subdirectories: subdirectories,
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

  /// The owner ids Android's `MediaStoreChannel.beginPending` accepts as a
  /// pending row's marker; it refuses any other, so the row is never made.
  static final idPattern = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');

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
    this.resumeAnchor,
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

  /// Preserved partial output for a resumable attempt (D8). When present the
  /// platform row/file must NOT be cleaned during recovery — it is the
  /// resume payload, not orphaned output.
  final ResumeAnchor? resumeAnchor;
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
      if (snapshot.subdirectories.isNotEmpty)
        'subdirectories': snapshot.subdirectories,
      'format': snapshot.format,
      'destination': snapshot.destination.identity,
      if (snapshot.request.namingRule != null)
        'namingPreset': snapshot.request.namingRule!.preset.code,
      if (snapshot.request.namingRule?.preset == NamingPreset.custom &&
          snapshot.request.namingRule?.template != null)
        'namingTemplate': snapshot.request.namingRule!.template,
      if (snapshot.request.artist != null) 'artist': snapshot.request.artist,
      if (snapshot.request.title != null) 'title': snapshot.request.title,
      if (snapshot.request.date != null)
        'date': snapshot.request.date!.toUtc().toIso8601String(),
      // Display-only fields (C5): optional, absent in old records.
      if (snapshot.request.totalPages != null)
        'totalPages': snapshot.request.totalPages,
      if (snapshot.request.thumbnailUrl != null)
        'thumbnailUrl': snapshot.request.thumbnailUrl,
      if (snapshot.accountId != null) 'accountId': snapshot.accountId,
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
    if (resumeAnchor != null) 'resumeAnchor': resumeAnchor!.toJson(),
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
    final rawPreset = rawSnapshot['namingPreset'];
    NamingRule? namingRule;
    if (rawPreset != null) {
      final preset = NamingPreset.fromCode(rawPreset);
      if (preset == NamingPreset.custom) {
        final template = rawSnapshot['namingTemplate'];
        if (template is String && NamingRule.isValidTemplate(template)) {
          namingRule = NamingRule(preset: preset, template: template);
        }
      } else {
        namingRule = NamingRule(preset: preset);
      }
    }
    final artist = rawSnapshot['artist'] is String
        ? rawSnapshot['artist'] as String
        : null;
    final title = rawSnapshot['title'] is String
        ? rawSnapshot['title'] as String
        : null;
    final date = rawSnapshot['date'] is String
        ? DateTime.tryParse(rawSnapshot['date'] as String)
        : null;
    // Optional display fields (C5): missing or mistyped values degrade to
    // null instead of rejecting the record.
    final totalPages = rawSnapshot['totalPages'] is int
        ? rawSnapshot['totalPages'] as int
        : null;
    final thumbnailUrl = rawSnapshot['thumbnailUrl'] is String
        ? rawSnapshot['thumbnailUrl'] as String
        : null;
    final rawSubdirectories = rawSnapshot['subdirectories'];
    final List<String> subdirectories;
    if (rawSubdirectories == null) {
      subdirectories = const [];
    } else if (rawSubdirectories is List) {
      final parsed = <String>[];
      for (final item in rawSubdirectories) {
        if (item is! String) {
          throw const DownloadRecoveryDataException(
            'snapshot subdirectories invalid',
          );
        }
        parsed.add(item);
      }
      try {
        validateSubdirectories(parsed);
      } on FormatException {
        throw const DownloadRecoveryDataException(
          'snapshot subdirectories invalid',
        );
      }
      subdirectories = List<String>.unmodifiable(parsed);
    } else {
      throw const DownloadRecoveryDataException(
        'snapshot subdirectories invalid',
      );
    }
    final request = DownloadRequest(
      illustId: rawSnapshot['illustId'] as int,
      pageIndex: rawSnapshot['pageIndex'] as int,
      url: Uri.parse(rawSnapshot['url'] as String),
      target: target,
      namingRule: namingRule,
      artist: artist,
      title: title,
      date: date,
      totalPages: totalPages,
      thumbnailUrl: thumbnailUrl,
      subdirectories: subdirectories,
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
    // The serialized name is the submission-time decision. A missing key
    // means a record written before it was persisted — fall back to
    // recomputing from the restored request.
    final rawDisplayName = rawSnapshot['displayName'];
    final String? displayName;
    if (rawDisplayName is String) {
      try {
        validateDisplayName(rawDisplayName);
      } on FormatException {
        throw const DownloadRecoveryDataException(
          'snapshot displayName invalid',
        );
      }
      displayName = rawDisplayName;
    } else if (!rawSnapshot.containsKey('displayName')) {
      displayName = null;
    } else {
      throw const DownloadRecoveryDataException('snapshot displayName invalid');
    }
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: rawSnapshot['snapshotId'] as String,
      jobId: rawSnapshot['jobId'] as String,
      groupId: rawSnapshot['groupId'] as String?,
      request: request,
      accountId: rawSnapshot['accountId'] as String?,
      submittedAt: submittedAt,
      destination: _destinationFromIdentity(
        rawSnapshot['destination'] as String?,
      ),
      displayName: displayName,
      subdirectories: subdirectories,
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
      resumeAnchor: _anchorFromJson(json['resumeAnchor']),
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
    this.supersededJobIds = const [],
    this.cleanupFailedJobIds = const [],
    this.cleanupFailedPendingOutputIds = const [],
    this.error,
  });

  final List<String> retryableJobIds;
  final List<String> orphanedJobIds;
  final List<int> orphanedPendingOutputIds;
  final List<String> restoredJobIds;
  final List<String> skippedJobIds;
  final List<String> supersededJobIds;
  final List<String> cleanupFailedJobIds;
  final List<int> cleanupFailedPendingOutputIds;
  final Object? error;
}

/// Store contract deliberately persists metadata only; credentials and
/// request headers never cross this boundary.
abstract interface class DownloadRecoveryStore {
  Future<List<DownloadRecoveryRecord>> load();

  Future<void> upsert(DownloadRecoveryRecord record);

  Future<void> upsertAll(List<DownloadRecoveryRecord> records);

  Future<void> remove(String jobId);

  Future<void> removeAll(Iterable<String> jobIds);
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
  Future<void> upsertAll(List<DownloadRecoveryRecord> records) async {
    for (final record in records) {
      _records[record.jobId] = record;
    }
  }

  @override
  Future<void> remove(String jobId) async {
    _records.remove(jobId);
  }

  @override
  Future<void> removeAll(Iterable<String> jobIds) async {
    for (final jobId in jobIds) {
      _records.remove(jobId);
    }
  }
}

final class _CachedRecoveryEntry {
  const _CachedRecoveryEntry(this.record, this.encoded, this.generation);

  final DownloadRecoveryRecord record;
  final String encoded;
  final int generation;
}

/// Versioned preferences store for app process recovery. Terminal records are
/// bounded so a long-lived app cannot turn task history into an unbounded
/// queue while active work remains recoverable.
class PreferencesDownloadRecoveryStore implements DownloadRecoveryStore {
  PreferencesDownloadRecoveryStore({
    required SharedPreferencesAsync preferences,
    String storageKey = PreferenceKeys.downloadRecovery,
  }) : _preferences = preferences,
       _storageKey = _validateStorageKey(storageKey);

  static const defaultStorageKey = PreferenceKeys.downloadRecovery;
  static const _maxRecords = 128;

  final SharedPreferencesAsync _preferences;
  final String _storageKey;
  Future<void> _writeTail = Future<void>.value();
  var _loaded = false;
  var _generation = 0;

  // Insertion-ordered cache keyed by jobId; each entry keeps its serialized
  // JSON so unchanged records are never re-encoded on subsequent writes.
  LinkedHashMap<String, _CachedRecoveryEntry> _cache = LinkedHashMap();
  Queue<(String, int)> _terminalQueue = Queue();

  @override
  Future<List<DownloadRecoveryRecord>> load() async {
    await _writeTail;
    await _ensureLoaded();
    return List.unmodifiable([for (final e in _cache.values) e.record]);
  }

  @override
  Future<void> upsert(DownloadRecoveryRecord record) => upsertAll([record]);

  @override
  Future<void> upsertAll(List<DownloadRecoveryRecord> records) {
    if (records.isEmpty) return Future<void>.value();
    return _enqueue(() async {
      await _ensureLoaded();
      final nextCache = LinkedHashMap<String, _CachedRecoveryEntry>.of(_cache);
      final nextTerminals = Queue<(String, int)>.of(_terminalQueue);
      var nextGen = _generation;
      for (final record in records) {
        final encoded = jsonEncode(record.toJson());
        final gen = ++nextGen;
        nextCache.remove(record.jobId);
        nextCache[record.jobId] = _CachedRecoveryEntry(record, encoded, gen);
        if (_isTerminalStatus(record.status)) {
          nextTerminals.addLast((record.jobId, gen));
        }
      }
      while (nextCache.length > _maxRecords && nextTerminals.isNotEmpty) {
        final (candidateId, gen) = nextTerminals.removeFirst();
        final existing = nextCache[candidateId];
        if (existing != null && existing.generation == gen) {
          nextCache.remove(candidateId);
        }
      }
      await _preferences.setStringList(_storageKey, [
        for (final entry in nextCache.values) entry.encoded,
      ]);
      _cache = nextCache;
      _terminalQueue = nextTerminals;
      _generation = nextGen;
    });
  }

  @override
  Future<void> remove(String jobId) => removeAll([jobId]);

  @override
  Future<void> removeAll(Iterable<String> jobIds) {
    final ids = jobIds is Set<String> ? jobIds : jobIds.toSet();
    if (ids.isEmpty) return Future<void>.value();
    return _enqueue(() async {
      await _ensureLoaded();
      final nextCache = LinkedHashMap<String, _CachedRecoveryEntry>.of(_cache);
      var removedAny = false;
      for (final id in ids) {
        if (nextCache.remove(id) != null) removedAny = true;
      }
      if (!removedAny) return;
      if (nextCache.isEmpty) {
        await _preferences.remove(_storageKey);
      } else {
        await _preferences.setStringList(_storageKey, [
          for (final entry in nextCache.values) entry.encoded,
        ]);
      }
      _cache = nextCache;
      if (nextCache.isEmpty) _terminalQueue.clear();
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeTail.then((_) => operation());
    _writeTail = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final raw = await _preferences.getStringList(_storageKey);
    _cache.clear();
    _terminalQueue.clear();
    if (raw != null) {
      for (final encoded in raw) {
        final record = DownloadRecoveryRecord.fromJson(
          (jsonDecode(encoded) as Map).cast<String, dynamic>(),
        );
        final gen = ++_generation;
        _cache.remove(record.jobId);
        _cache[record.jobId] = _CachedRecoveryEntry(record, encoded, gen);
        if (_isTerminalStatus(record.status)) {
          _terminalQueue.addLast((record.jobId, gen));
        }
      }
    }
    _loaded = true;
  }

  static bool _isTerminalStatus(DownloadStatus status) => switch (status) {
    DownloadStatus.succeeded ||
    DownloadStatus.failed ||
    DownloadStatus.canceled ||
    DownloadStatus.orphaned => true,
    _ => false,
  };

  static String _validateStorageKey(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, 'storageKey', 'must not be empty');
    }
    return value;
  }
}

/// Coalesces per-turn recovery store writes and removals into one serialized
/// batch per microtask so group submissions and synchronous status transitions
/// avoid N+1 preference writes while [flush] commits immediately.
class DownloadPersistenceCoalescer {
  DownloadPersistenceCoalescer(
    this._store, {
    required void Function(Object error) onError,
  }) : _onError = onError;

  final DownloadRecoveryStore _store;
  final void Function(Object error) _onError;
  final Map<String, DownloadRecoveryRecord> _pendingUpserts = {};
  final Set<String> _pendingRemovals = {};
  Future<void> _tail = Future<void>.value();
  var _flushScheduled = false;

  void upsert(DownloadRecoveryRecord record) {
    _pendingRemovals.remove(record.jobId);
    _pendingUpserts[record.jobId] = record;
    _schedule();
  }

  void remove(String jobId) {
    _pendingUpserts.remove(jobId);
    _pendingRemovals.add(jobId);
    _schedule();
  }

  Future<void> flush() {
    _drain();
    return _tail;
  }

  void _schedule() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(_drain);
  }

  void _drain() {
    _flushScheduled = false;
    if (_pendingRemovals.isEmpty && _pendingUpserts.isEmpty) return;
    final removals = _pendingRemovals.isEmpty
        ? const <String>[]
        : _pendingRemovals.toList(growable: false);
    final upserts = _pendingUpserts.isEmpty
        ? const <DownloadRecoveryRecord>[]
        : _pendingUpserts.values.toList(growable: false);
    _pendingRemovals.clear();
    _pendingUpserts.clear();
    _tail = _tail.then((_) async {
      if (removals.isNotEmpty) {
        try {
          await _store.removeAll(removals);
        } on Object catch (error) {
          _onError(error);
        }
      }
      if (upserts.isNotEmpty) {
        try {
          await _store.upsertAll(upserts);
        } on Object catch (error) {
          _onError(error);
        }
      }
    });
  }
}

class DownloadRecoveryDataException implements Exception {
  const DownloadRecoveryDataException(this.message);

  final String message;

  @override
  String toString() => 'DownloadRecoveryDataException: $message';
}

/// Lenient anchor parse: a corrupt anchor degrades to null so the record
/// still loads and the attempt simply restarts without resume (D8).
ResumeAnchor? _anchorFromJson(Object? raw) {
  if (raw is! Map) return null;
  try {
    return ResumeAnchor.fromJson(raw.cast<String, dynamic>());
  } on Object {
    return null;
  }
}

/// Parses the durable destination identity (D5). Legacy records stored the
/// raw 'Pictures/Parfait' path; both map to the built-in album.
DownloadDestination _destinationFromIdentity(String? identity) {
  if (identity == null || identity.isEmpty) return DownloadDestination.builtin;
  if (identity == 'Pictures/Parfait') return DownloadDestination.builtin;
  if (identity == 'album:parfait') {
    return DownloadDestination.builtin;
  }
  if (identity.startsWith('album:')) {
    final name = identity.substring('album:'.length);
    final normalized = DownloadDestination.normalizeAlbumName(name);
    if (normalized != null) {
      return DownloadDestination.customAlbum(normalized);
    }
    return DownloadDestination.builtin;
  }
  if (identity.startsWith('saf:')) {
    final uri = identity.substring('saf:'.length);
    if (uri.isNotEmpty) return DownloadDestination.safFolder(uri);
  }
  return DownloadDestination.builtin;
}
