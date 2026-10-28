import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'helpers/waits.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart';
import 'package:parfait/core/platform/android_platform_interfaces.dart';
import 'package:parfait/core/ugoira/ugoira_recovery.dart';

DownloadRequest _request({int pageIndex = 0}) => DownloadRequest(
  illustId: 900,
  pageIndex: pageIndex,
  url: Uri.parse('https://i.pximg.net/img-original/img/900_p$pageIndex.jpg'),
  target: DownloadTarget.illustPage,
);

DownloadSubmissionContext _context({String accountId = 'account-a'}) =>
    DownloadSubmissionContext(accountId: accountId);

DownloadRecoveryRecord _record(
  String jobId, {
  DownloadRequest? request,
  String? groupId,
  DownloadStatus status = DownloadStatus.running,
  DateTime? submittedAt,
  int? pendingMediaStoreId,
  String? finalUri,
}) {
  final snapshot = DownloadSubmissionSnapshot(
    snapshotId: 'submission-$jobId',
    jobId: jobId,
    groupId: groupId,
    request: request ?? _request(),
    accountId: 'account-a',
    submittedAt: submittedAt ?? DateTime.utc(2026, 8, 28),
  );
  return DownloadRecoveryRecord(
    jobId: jobId,
    dedupeKey: snapshot.request.dedupeKey,
    snapshot: snapshot,
    owner: DownloadOutputOwner(
      ownerId: 'output-$jobId',
      jobId: jobId,
      accountId: snapshot.accountId,
    ),
    status: status,
    pendingMediaStoreId: pendingMediaStoreId,
    finalUri: finalUri,
  );
}

DownloadRecoveryRecord _recoveryRecord(
  int index, {
  required DownloadStatus status,
}) => _record(
  'job-$index',
  request: _request(pageIndex: index),
  status: status,
  submittedAt: DateTime.utc(2026, 9, 1).add(Duration(minutes: index)),
);

/// `{author_id}`/`{w}`/`{h}` come from submission-time metadata that a
/// recovery record never persists.
DownloadRequest _customNamedRequest() => DownloadRequest(
  illustId: 123,
  pageIndex: 0,
  url: Uri.parse('https://i.pximg.net/img-original/img/123_p0.jpg'),
  target: DownloadTarget.illustPage,
  namingRule: const NamingRule(
    preset: NamingPreset.custom,
    template: '{author_id}_{w}x{h}_{id}_p{page}',
  ),
  authorId: 42,
  width: 100,
  height: 200,
);

Future<MemoryDownloadRecoveryStore> _storeWith(
  List<DownloadRecoveryRecord> records,
) async {
  final store = MemoryDownloadRecoveryStore();
  for (final record in records) {
    await store.upsert(record);
  }
  return store;
}

/// A manager submitting for [accountId], disposed when the test ends.
DownloadManager _manager({
  DownloadRecoveryStore? store,
  DownloadSinkFactory? sinks,
  DownloadTransport? transport,
  String accountId = 'account-a',
}) {
  final manager = DownloadManager(
    transport: transport ?? _Transport(_Response()),
    sinkFactory: sinks ?? MemorySinkFactory(),
    submissionContext: () => _context(accountId: accountId),
    recoveryStore: store,
  );
  addTearDown(manager.dispose);
  return manager;
}

class _Response implements DownloadResponse, DownloadResponseMetadata {
  _Response({
    this.statusCode = 200,
    this.headers = const {},
    this.body = const [],
  });

  @override
  final int statusCode;

  @override
  final Map<String, String> headers;

  final List<List<int>> body;

  @override
  int get contentLength =>
      body.fold<int>(0, (total, chunk) => total + chunk.length);

  @override
  Stream<List<int>> get stream => Stream.fromIterable(body);

  @override
  Future<void> close() async {}
}

class _Transport implements DownloadTransport {
  _Transport(this.response);

  final DownloadResponse response;
  var opens = 0;

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    opens++;
    return response;
  }
}

class _CancelErrorTransport implements DownloadTransport {
  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    await cancelToken.whenCancel;
    throw DownloadTransportException('socket closed after cancel');
  }
}

class _FinalizeGateSink implements DownloadSink {
  _FinalizeGateSink(this.gate);

  final Completer<void> gate;
  var finalizeCalls = 0;
  var abortCalls = 0;

  @override
  Future<void> write(List<int> bytes) async {}

  @override
  Future<String> finalize() async {
    finalizeCalls++;
    await gate.future;
    return 'content://recovery/1';
  }

  @override
  Future<void> abort() async {
    abortCalls++;
  }
}

class _FinalizeGateSinkFactory implements DownloadSinkFactory {
  _FinalizeGateSinkFactory(this.sink);

  final _FinalizeGateSink sink;

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async => sink;
}

class _RecoverableSinkFactory extends MemorySinkFactory
    implements RecoverableDownloadSinkFactory {
  _RecoverableSinkFactory(this.pending, {this.cleanupSucceeds = true});

  final List<PendingMediaStoreItem> pending;
  final bool cleanupSucceeds;
  final cleaned = <String>[];

  @override
  Future<List<PendingMediaStoreItem>> listPending() async => pending;

  @override
  Future<bool> cleanupPending(
    int id, {
    required DownloadOutputOwner owner,
  }) async {
    cleaned.add('$id:${owner.ownerId}');
    return cleanupSucceeds;
  }
}

void main() {
  test(
    'preferences recovery store round-trips only bounded metadata',
    () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final preferences = SharedPreferencesAsync();
      final store = PreferencesDownloadRecoveryStore(preferences: preferences);
      await store.upsert(
        _record(
          'job-round-trip',
          status: DownloadStatus.finalizing,
          pendingMediaStoreId: 41,
        ),
      );

      final reloaded = PreferencesDownloadRecoveryStore(
        preferences: preferences,
      );
      final records = await reloaded.load();
      expect(records, hasLength(1));
      expect(records.single.snapshot.accountId, 'account-a');
      expect(records.single.pendingMediaStoreId, 41);
      expect(records.single.toJson().toString(), isNot(contains('token')));
    },
  );

  test(
    'recovery store evicts terminal records before active records',
    () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final preferences = SharedPreferencesAsync();
      final store = PreferencesDownloadRecoveryStore(preferences: preferences);

      await store.upsert(_recoveryRecord(0, status: DownloadStatus.running));
      for (var index = 1; index <= 128; index++) {
        await store.upsert(
          _recoveryRecord(index, status: DownloadStatus.succeeded),
        );
      }

      final records = await store.load();
      expect(records, hasLength(128));
      expect(records.map((record) => record.jobId), contains('job-0'));
      expect(records.map((record) => record.jobId), isNot(contains('job-1')));
      expect(records.map((record) => record.jobId), contains('job-128'));

      final reloaded = PreferencesDownloadRecoveryStore(
        preferences: preferences,
      );
      final persistedRecords = await reloaded.load();
      expect(persistedRecords, hasLength(128));
      expect(persistedRecords.map((record) => record.jobId), contains('job-0'));
    },
  );

  test(
    'legacy Pictures/Parfait destination migrates to the builtin owner',
    () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final preferences = SharedPreferencesAsync();
      final raw = <String, Object?>{
        'jobId': 'job-legacy-path',
        'dedupeKey':
            'illustPage|900|0|https://i.pximg.net/img-original/img/900_p0.jpg',
        'snapshot': {
          'snapshotId': 'snap-legacy-path',
          'jobId': 'job-legacy-path',
          'illustId': 900,
          'pageIndex': 0,
          'url': 'https://i.pximg.net/img-original/img/900_p0.jpg',
          'target': 'illustPage',
          'displayName': '900_p0.jpg',
          'format': 'image/jpeg',
          'destination': 'Pictures/Parfait',
          'accountId': 'account-a',
          'submittedAt': '2026-09-01T00:00:00.000Z',
        },
        'owner': {
          'ownerId': 'output-legacy',
          'jobId': 'job-legacy-path',
          'accountId': 'account-a',
        },
        'status': 'retryable',
        'receivedBytes': 0,
      };
      await preferences.setStringList(
        PreferencesDownloadRecoveryStore.defaultStorageKey,
        [jsonEncode(raw)],
      );

      final records = await PreferencesDownloadRecoveryStore(
        preferences: preferences,
      ).load();
      expect(records, hasLength(1));
      expect(records.single.snapshot.destination, DownloadDestination.builtin);
      const current = DownloadSubmissionContext(accountId: 'account-a');
      expect(records.single.snapshot.accountId, current.accountId);
      expect(
        records.single.snapshot.destination.identity,
        current.destination.identity,
      );
    },
  );

  test(
    'keeps finalizing visible until the sink is finalized exactly once',
    () async {
      final gate = Completer<void>();
      final sink = _FinalizeGateSink(gate);
      final manager = _manager(
        transport: _Transport(
          _Response(
            body: const [
              [1, 2, 3],
            ],
          ),
        ),
        sinks: _FinalizeGateSinkFactory(sink),
      );

      final events = <DownloadEvent>[];
      final subscription = manager.events.listen(events.add);
      final task = manager.submit(_request());
      await turnUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.finalizing,
      );

      expect(manager.taskById(task.id)!.submission!.accountId, 'account-a');
      expect(manager.taskById(task.id)!.status, DownloadStatus.finalizing);
      expect(events, isEmpty);

      gate.complete();
      await turnUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.succeeded,
      );
      expect(sink.finalizeCalls, 1);
      expect(sink.abortCalls, 0);
      expect(events.map((event) => event.kind), [DownloadEventKind.succeeded]);
      await subscription.cancel();
    },
  );

  test('recovery preserves naming metadata across a process restart', () {
    const namingRule = NamingRule(
      preset: NamingPreset.custom,
      template: '{artist}_{title}_{id}_p{page}.{ext}',
    );
    final record = _record(
      'job-naming',
      request: DownloadRequest(
        illustId: 901,
        pageIndex: 3,
        url: Uri.parse('https://i.pximg.net/img/901_p3.jpg'),
        target: DownloadTarget.illustPage,
        namingRule: namingRule,
        artist: 'artist',
        title: 'title',
        date: DateTime.utc(2026, 9, 3),
        totalPages: 6,
        thumbnailUrl: 'https://i.pximg.net/901/p3/s.jpg',
      ),
    );

    final restored = DownloadRecoveryRecord.fromJson(
      record.toJson().cast<String, dynamic>(),
    );

    expect(restored.snapshot.request.namingRule, namingRule);
    expect(restored.snapshot.request.artist, 'artist');
    expect(restored.snapshot.request.title, 'title');
    expect(restored.snapshot.request.date, DateTime.utc(2026, 9, 3));
    expect(restored.snapshot.request.totalPages, 6);
    expect(
      restored.snapshot.request.thumbnailUrl,
      'https://i.pximg.net/901/p3/s.jpg',
    );
    expect(restored.snapshot.displayName, 'artist_title_901_p3.jpg');
  });

  test('records without display fields still recover', () {
    final record = _record(
      'job-legacy',
      request: DownloadRequest(
        illustId: 902,
        pageIndex: 0,
        url: Uri.parse('https://i.pximg.net/img/902_p0.jpg'),
        target: DownloadTarget.illustPage,
        title: 'title',
      ),
    );

    // A record written before the display fields existed carries neither
    // key; a mistyped value degrades to null instead of rejecting the row.
    final json = record.toJson().cast<String, dynamic>();
    (json['snapshot'] as Map<String, dynamic>)
      ..remove('totalPages')
      ..remove('thumbnailUrl');
    final legacy = DownloadRecoveryRecord.fromJson(json);
    expect(legacy.snapshot.request.totalPages, isNull);
    expect(legacy.snapshot.request.thumbnailUrl, isNull);
    expect(legacy.snapshot.request.title, 'title');

    final mistyped = record.toJson().cast<String, dynamic>();
    (mistyped['snapshot'] as Map<String, dynamic>)
      ..['totalPages'] = '3'
      ..['thumbnailUrl'] = 7;
    final restored = DownloadRecoveryRecord.fromJson(mistyped);
    expect(restored.snapshot.request.totalPages, isNull);
    expect(restored.snapshot.request.thumbnailUrl, isNull);
  });

  test('classifies rate limiting and preserves Retry-After', () async {
    final manager = _manager(
      transport: _Transport(
        _Response(statusCode: 429, headers: const {'retry-after': '12'}),
      ),
    );

    final task = manager.submit(_request());
    await turnUntil(
      () => manager.taskById(task.id)?.status == DownloadStatus.failed,
    );
    final failed = manager.taskById(task.id)!;
    expect(failed.failureKind, DownloadFailureKind.rateLimit);
    expect(failed.retryAfter, const Duration(seconds: 12));
    expect(failed.error, contains('429'));
  });

  test('transport errors after cancellation keep the task canceled', () async {
    final manager = _manager(transport: _CancelErrorTransport());

    final task = manager.submit(_request());
    await turnUntil(
      () => manager.taskById(task.id)?.status == DownloadStatus.running,
    );
    await manager.cancel(task.id);
    await turnUntil(
      () => manager.taskById(task.id)?.status == DownloadStatus.canceled,
    );

    expect(
      manager.taskById(task.id)!.failureKind,
      DownloadFailureKind.canceled,
    );
  });

  test('recovery only exposes same-owner pending work as retryable', () async {
    final store = await _storeWith([_record('job-1', pendingMediaStoreId: 17)]);
    final transport = _Transport(
      _Response(
        body: const [
          [1],
        ],
      ),
    );
    final manager = _manager(store: store, transport: transport);

    final report = await manager.recover();
    expect(report.retryableJobIds, ['job-1']);
    expect(manager.taskById('job-1')!.status, DownloadStatus.retryable);
    expect(manager.taskById('job-1')!.submission!.accountId, 'account-a');
    expect(transport.opens, 0, reason: 'recovery requires an explicit retry');

    final otherStore = await _storeWith([
      _record(
        'job-2',
        status: DownloadStatus.finalizing,
        pendingMediaStoreId: 18,
      ),
    ]);
    final otherManager = _manager(store: otherStore, accountId: 'account-b');
    await otherManager.recover();
    expect(otherManager.taskById('job-2')!.status, DownloadStatus.orphaned);
  });

  test(
    'finalizing recovery becomes orphaned instead of retrying post-process',
    () async {
      final store = await _storeWith([
        _record(
          'job-finalizing',
          status: DownloadStatus.finalizing,
          pendingMediaStoreId: 34,
        ),
      ]);
      final sinks = _RecoverableSinkFactory([
        const PendingMediaStoreItem(
          id: 34,
          ownerId: 'output-job-finalizing',
          displayName: '900_p0.jpg',
        ),
      ]);
      final manager = _manager(store: store, sinks: sinks);
      final events = <DownloadEvent>[];
      final subscription = manager.events.listen(events.add);

      final report = await manager.recover();

      expect(report.retryableJobIds, isEmpty);
      expect(report.orphanedJobIds, ['job-finalizing']);
      expect(sinks.cleaned, ['34:output-job-finalizing']);
      expect(
        manager.taskById('job-finalizing')!.status,
        DownloadStatus.orphaned,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => event.kind), [DownloadEventKind.orphaned]);
      await subscription.cancel();
    },
  );

  test(
    'restart scan cleans only recorded owners and reports unknown rows',
    () async {
      final store = await _storeWith([
        _record('job-scan', request: _request(pageIndex: 2)),
      ]);
      final sinks = _RecoverableSinkFactory([
        const PendingMediaStoreItem(
          id: 31,
          ownerId: 'output-job-scan',
          displayName: '902_p2.jpg',
        ),
        const PendingMediaStoreItem(
          id: 32,
          ownerId: 'output-unknown',
          displayName: 'unknown.jpg',
        ),
        const PendingMediaStoreItem(
          id: 33,
          ownerId: null,
          displayName: 'legacy.jpg',
        ),
      ]);
      final manager = _manager(store: store, sinks: sinks);

      final report = await manager.recover();

      expect(sinks.cleaned, ['31:output-job-scan']);
      expect(report.retryableJobIds, ['job-scan']);
      expect(report.orphanedPendingOutputIds, [32, 33]);
      expect(report.cleanupFailedPendingOutputIds, isEmpty);
    },
  );

  test('recovery reports a platform owner-cleanup refusal', () async {
    final store = await _storeWith([
      _record('job-refused', pendingMediaStoreId: 44),
    ]);
    final sinks = _RecoverableSinkFactory(const [
      PendingMediaStoreItem(
        id: 44,
        ownerId: 'output-job-refused',
        displayName: '900_p0.jpg',
      ),
    ], cleanupSucceeds: false);
    final manager = _manager(store: store, sinks: sinks);

    final report = await manager.recover();

    expect(report.cleanupFailedJobIds, ['job-refused']);
    expect(report.cleanupFailedPendingOutputIds, [44]);
    expect(manager.taskById('job-refused')!.status, DownloadStatus.retryable);
  });

  test(
    'group submission gives every child the same immutable group boundary',
    () {
      final manager = _manager();

      final group = manager.submitGroup([_request(), _request(pageIndex: 1)]);
      expect(group.jobIds, hasLength(2));
      expect(group.submission.accountId, 'account-a');
      expect(
        group.jobIds
            .map(manager.taskById)
            .every((task) => task!.groupId == group.id),
        isTrue,
      );
      expect(
        group.jobIds
            .map(manager.taskById)
            .every((task) => task!.submission!.groupId == group.id),
        isTrue,
      );
    },
  );

  test('restart recovery reconstructs a group from child snapshots', () async {
    const groupId = 'group-restart';
    final store = await _storeWith([
      _record('job-group-1', groupId: groupId),
      _record(
        'job-group-2',
        request: _request(pageIndex: 1),
        groupId: groupId,
        status: DownloadStatus.succeeded,
        finalUri: 'content://media/external/images/media/2',
      ),
    ]);
    final manager = _manager(store: store);
    var changes = 0;
    final changesSubscription = manager.changes.listen((_) => changes++);

    await manager.recover();

    final group = manager.groupById(groupId);
    expect(group, isNotNull);
    expect(group!.jobIds, ['job-group-1', 'job-group-2']);
    expect(group.status, DownloadGroupStatus.retryable);
    expect(manager.taskById('job-group-1')!.status, DownloadStatus.retryable);
    expect(manager.taskById('job-group-2')!.status, DownloadStatus.succeeded);
    await Future<void>.delayed(Duration.zero);
    expect(changes, greaterThan(0));
    await changesSubscription.cancel();
  });

  test('a group made after a restart never joins a recovered one', () async {
    // Group ids once restarted from 0 with every launch, so each launch's
    // first download landed in the same group.
    final store = MemoryDownloadRecoveryStore();
    DownloadManager launch() => DownloadManager(
      transport: _Transport(_Response(body: const [])),
      sinkFactory: MemorySinkFactory(),
      submissionContext: () => _context(),
      recoveryStore: store,
    );
    final first = launch();
    final before = first.submitGroup([_request()]);
    await first.flushPersistence();
    await first.dispose();

    final second = launch();
    addTearDown(second.dispose);
    await second.recover();
    final after = second.submitGroup([
      DownloadRequest(
        illustId: 901,
        pageIndex: 0,
        url: Uri.parse('https://i.pximg.net/img-original/img/901_p0.jpg'),
        target: DownloadTarget.illustPage,
      ),
    ]);

    expect(after.id, isNot(before.id));
    expect(after.jobIds.single, isNot(before.jobIds.single));
    expect(second.groupById(before.id)!.jobIds, before.jobIds);
    expect(second.groupById(after.id)!.jobIds, after.jobIds);
  });

  test('recovery keeps the newest record for one identity', () async {
    final store = await _storeWith([
      _record(
        'job-old',
        groupId: 'group-old',
        submittedAt: DateTime.utc(2026, 9, 1),
      ),
      _record(
        'job-new',
        groupId: 'group-new',
        submittedAt: DateTime.utc(2026, 9, 1, 0, 1),
      ),
    ]);
    final manager = _manager(store: store);

    final report = await manager.recover();

    expect(report.supersededJobIds, ['job-old']);
    expect(manager.taskById('job-old'), isNull);
    expect(manager.taskById('job-new')!.status, DownloadStatus.retryable);
    expect(manager.groupById('group-old'), isNull);
    expect(manager.groupById('group-new')!.jobIds, ['job-new']);
    await manager.flushPersistence();
    expect(store.records.map((record) => record.jobId), ['job-new']);
  });

  test('a custom-template file name survives recovery unchanged', () {
    // The frozen serialized name must be used.
    final record = _record(
      'job-name',
      request: _customNamedRequest(),
      status: DownloadStatus.queued,
    );

    final restored = DownloadRecoveryRecord.fromJson(
      (jsonDecode(jsonEncode(record.toJson())) as Map).cast<String, dynamic>(),
    );

    expect(restored.snapshot.displayName, '42_100x200_123_p0');
  });

  test('a stored name with traversal segments is rejected', () {
    final record = _recoveryRecord(0, status: DownloadStatus.queued);
    final json = (jsonDecode(jsonEncode(record.toJson())) as Map)
        .cast<String, dynamic>();
    (json['snapshot'] as Map<String, dynamic>)['displayName'] = '../evil.jpg';

    expect(
      () => DownloadRecoveryRecord.fromJson(json),
      throwsA(
        isA<DownloadRecoveryDataException>().having(
          (error) => error.message,
          'message',
          'snapshot displayName invalid',
        ),
      ),
    );
  });

  test('a record without a stored name falls back to the request', () {
    final record = _recoveryRecord(0, status: DownloadStatus.queued);
    final json = (jsonDecode(jsonEncode(record.toJson())) as Map)
        .cast<String, dynamic>();
    (json['snapshot'] as Map<String, dynamic>).remove('displayName');

    final restored = DownloadRecoveryRecord.fromJson(json);

    expect(restored.snapshot.displayName, record.snapshot.request.displayName);
  });

  test('retrying a recovered task writes the stored name', () async {
    // The recovered request lacks `{author_id}`/`{w}`/`{h}`, so a retry that
    // recomputed the name would hand the sink `_x_123_p0`.
    final record = _record('job-retry', request: _customNamedRequest());
    final store = await _storeWith([
      DownloadRecoveryRecord.fromJson(
        (jsonDecode(jsonEncode(record.toJson())) as Map)
            .cast<String, dynamic>(),
      ),
    ]);
    final sinkFactory = _NameRecordingSinkFactory();
    final manager = _manager(
      store: store,
      sinks: sinkFactory,
      transport: _Transport(
        _Response(
          body: const [
            [1],
          ],
        ),
      ),
    );

    await manager.recover();
    expect(manager.taskById('job-retry')!.displayName, '42_100x200_123_p0');

    final retried = manager.retry('job-retry')!;
    await turnUntil(
      () => manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
    );

    expect(retried.displayName, '42_100x200_123_p0');
    expect(sinkFactory.names, ['42_100x200_123_p0']);
  });

  group('ugoira recovery', () {
    test(
      'interrupted Ugoira output is orphaned and its owned pending row is cleaned',
      () async {
        final store = MemoryDownloadRecoveryStore();
        final factory = _RecoverySinkFactory(
          pending: [
            const PendingMediaStoreItem(
              id: 71,
              ownerId: 'ugoira-output-ugoira-1',
              displayName: '1.gif',
            ),
            const PendingMediaStoreItem(
              id: 72,
              ownerId: 'ugoira-output-unknown',
              displayName: 'unknown.gif',
            ),
            const PendingMediaStoreItem(
              id: 73,
              ownerId: 'output-download-1',
              displayName: 'download.jpg',
            ),
          ],
        );
        final submission = DownloadSubmissionSnapshot(
          snapshotId: 'submission-ugoira-1',
          jobId: 'ugoira-1',
          groupId: 'group-1',
          request: DownloadRequest(
            illustId: 1,
            pageIndex: 0,
            url: Uri.parse('https://i.pximg.net/img-ugoira-export/1.gif'),
            target: DownloadTarget.ugoiraGif,
          ),
          accountId: 'account-a',
          submittedAt: DateTime.utc(2026, 8, 28),
        );
        final owner = const DownloadOutputOwner(
          ownerId: 'ugoira-output-ugoira-1',
          jobId: 'ugoira-1',
          accountId: 'account-a',
        );
        await store.upsert(
          DownloadRecoveryRecord(
            jobId: 'ugoira-1',
            dedupeKey: 'ugoira/ugoira-1',
            snapshot: submission,
            owner: owner,
            status: DownloadStatus.finalizing,
            pendingMediaStoreId: 71,
          ),
        );

        final report = await recoverUgoiraExports(
          store: store,
          sinkFactory: factory,
        );

        expect(report.orphanedJobIds, ['ugoira-1']);
        expect(report.orphanedPendingOutputIds, [72]);
        expect(factory.cleaned, [71]);
        final recovered = (await store.load()).single;
        expect(recovered.status, DownloadStatus.orphaned);
        expect(recovered.pendingMediaStoreId, isNull);
      },
    );
  });
}

class _NameRecordingSinkFactory extends MemorySinkFactory {
  final names = <String>[];

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) {
    names.add(displayName);
    return super.begin(request, displayName, destination: destination);
  }
}

class _RecoverySinkFactory
    implements
        DownloadSinkFactory,
        OwnedDownloadSinkFactory,
        RecoverableDownloadSinkFactory {
  _RecoverySinkFactory({required List<PendingMediaStoreItem> pending})
    : _pending = pending;

  final List<PendingMediaStoreItem> _pending;
  final cleaned = <int>[];

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async => MemorySink();

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) => begin(request, displayName, destination: destination);

  @override
  Future<List<PendingMediaStoreItem>> listPending() async => _pending;

  @override
  Future<bool> cleanupPending(
    int id, {
    required DownloadOutputOwner owner,
  }) async {
    final index = _pending.indexWhere(
      (item) => item.id == id && item.ownerId == owner.ownerId,
    );
    if (index < 0) return false;
    _pending.removeAt(index);
    cleaned.add(id);
    return true;
  }
}
