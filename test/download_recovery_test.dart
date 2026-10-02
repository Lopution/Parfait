import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
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

DownloadRequest _request({int pageIndex = 0}) => DownloadRequest(
  illustId: 900,
  pageIndex: pageIndex,
  url: Uri.parse('https://i.pximg.net/img-original/img/900_p$pageIndex.jpg'),
  target: DownloadTarget.illustPage,
);

DownloadSubmissionContext _context({String accountId = 'account-a'}) =>
    DownloadSubmissionContext(accountId: accountId);

DownloadRecoveryRecord _recoveryRecord(
  int index, {
  required DownloadStatus status,
}) {
  final request = _request(pageIndex: index);
  final snapshot = DownloadSubmissionSnapshot(
    snapshotId: 'submission-$index',
    jobId: 'job-$index',
    groupId: null,
    request: request,
    accountId: 'account-a',
    submittedAt: DateTime.utc(2026, 9, 1).add(Duration(minutes: index)),
  );
  return DownloadRecoveryRecord(
    jobId: snapshot.jobId,
    dedupeKey: request.dedupeKey,
    snapshot: snapshot,
    owner: DownloadOutputOwner(
      ownerId: 'output-$index',
      jobId: snapshot.jobId,
      accountId: snapshot.accountId,
    ),
    status: status,
  );
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

Future<void> _pumpUntil(bool Function() predicate, {int attempts = 500}) async {
  for (var i = 0; i < attempts; i++) {
    await Future<void>.delayed(Duration.zero);
    if (predicate()) return;
  }
  fail('condition was not reached');
}

void main() {
  test(
    'preferences recovery store round-trips only bounded metadata',
    () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final preferences = SharedPreferencesAsync();
      final store = PreferencesDownloadRecoveryStore(preferences: preferences);
      final request = _request();
      final snapshot = DownloadSubmissionSnapshot(
        snapshotId: 'submission-round-trip',
        jobId: 'job-round-trip',
        groupId: null,
        request: request,
        accountId: 'account-a',
        submittedAt: DateTime.utc(2026, 8, 28),
      );
      await store.upsert(
        DownloadRecoveryRecord(
          jobId: snapshot.jobId,
          dedupeKey: request.dedupeKey,
          snapshot: snapshot,
          owner: const DownloadOutputOwner(
            ownerId: 'output-round-trip',
            jobId: 'job-round-trip',
            accountId: 'account-a',
          ),
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
      final manager = DownloadManager(
        transport: _Transport(
          _Response(
            body: const [
              [1, 2, 3],
            ],
          ),
        ),
        sinkFactory: _FinalizeGateSinkFactory(sink),
        submissionContext: () => _context(),
      );
      addTearDown(manager.dispose);

      final events = <DownloadEvent>[];
      final subscription = manager.events.listen(events.add);
      final task = manager.submit(_request());
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.finalizing,
      );

      expect(manager.taskById(task.id)!.submission!.accountId, 'account-a');
      expect(manager.taskById(task.id)!.status, DownloadStatus.finalizing);
      expect(events, isEmpty);

      gate.complete();
      await _pumpUntil(
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
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-naming',
      jobId: 'job-naming',
      groupId: null,
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
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 3),
    );
    final record = DownloadRecoveryRecord(
      jobId: snapshot.jobId,
      dedupeKey: snapshot.request.dedupeKey,
      snapshot: snapshot,
      owner: const DownloadOutputOwner(
        ownerId: 'output-naming',
        jobId: 'job-naming',
        accountId: 'account-a',
      ),
      status: DownloadStatus.running,
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
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-legacy',
      jobId: 'job-legacy',
      groupId: null,
      request: DownloadRequest(
        illustId: 902,
        pageIndex: 0,
        url: Uri.parse('https://i.pximg.net/img/902_p0.jpg'),
        target: DownloadTarget.illustPage,
        title: 'title',
      ),
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 3),
    );
    final record = DownloadRecoveryRecord(
      jobId: snapshot.jobId,
      dedupeKey: snapshot.request.dedupeKey,
      snapshot: snapshot,
      owner: const DownloadOutputOwner(
        ownerId: 'output-legacy',
        jobId: 'job-legacy',
        accountId: 'account-a',
      ),
      status: DownloadStatus.running,
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
    final manager = DownloadManager(
      transport: _Transport(
        _Response(statusCode: 429, headers: const {'retry-after': '12'}),
      ),
      sinkFactory: MemorySinkFactory(),
    );
    addTearDown(manager.dispose);

    final task = manager.submit(_request());
    await _pumpUntil(
      () => manager.taskById(task.id)?.status == DownloadStatus.failed,
    );
    final failed = manager.taskById(task.id)!;
    expect(failed.failureKind, DownloadFailureKind.rateLimit);
    expect(failed.retryAfter, const Duration(seconds: 12));
    expect(failed.error, contains('429'));
  });

  test('transport errors after cancellation keep the task canceled', () async {
    final manager = DownloadManager(
      transport: _CancelErrorTransport(),
      sinkFactory: MemorySinkFactory(),
    );
    addTearDown(manager.dispose);

    final task = manager.submit(_request());
    await _pumpUntil(
      () => manager.taskById(task.id)?.status == DownloadStatus.running,
    );
    await manager.cancel(task.id);
    await _pumpUntil(
      () => manager.taskById(task.id)?.status == DownloadStatus.canceled,
    );

    expect(
      manager.taskById(task.id)!.failureKind,
      DownloadFailureKind.canceled,
    );
  });

  test('recovery only exposes same-owner pending work as retryable', () async {
    final request = _request();
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-1',
      jobId: 'job-1',
      groupId: null,
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 8, 28),
    );
    final store = MemoryDownloadRecoveryStore();
    await store.upsert(
      DownloadRecoveryRecord(
        jobId: 'job-1',
        dedupeKey: request.dedupeKey,
        snapshot: snapshot,
        owner: const DownloadOutputOwner(
          ownerId: 'output-job-1',
          jobId: 'job-1',
          accountId: 'account-a',
        ),
        status: DownloadStatus.running,
        pendingMediaStoreId: 17,
      ),
    );

    final transport = _Transport(
      _Response(
        body: const [
          [1],
        ],
      ),
    );
    final manager = DownloadManager(
      transport: transport,
      sinkFactory: MemorySinkFactory(),
      submissionContext: () => _context(),
      recoveryStore: store,
    );
    addTearDown(manager.dispose);

    final report = await manager.recover();
    expect(report.retryableJobIds, ['job-1']);
    expect(manager.taskById('job-1')!.status, DownloadStatus.retryable);
    expect(manager.taskById('job-1')!.submission!.accountId, 'account-a');
    expect(transport.opens, 0, reason: 'recovery requires an explicit retry');

    final otherStore = MemoryDownloadRecoveryStore();
    await otherStore.upsert(
      DownloadRecoveryRecord(
        jobId: 'job-2',
        dedupeKey: request.dedupeKey,
        snapshot: snapshot.copyWith(jobId: 'job-2'),
        owner: const DownloadOutputOwner(
          ownerId: 'output-job-2',
          jobId: 'job-2',
          accountId: 'account-a',
        ),
        status: DownloadStatus.finalizing,
        pendingMediaStoreId: 18,
      ),
    );
    final otherManager = DownloadManager(
      transport: _Transport(
        _Response(
          body: const [
            [1],
          ],
        ),
      ),
      sinkFactory: MemorySinkFactory(),
      submissionContext: () => _context(accountId: 'account-b'),
      recoveryStore: otherStore,
    );
    addTearDown(otherManager.dispose);
    await otherManager.recover();
    expect(otherManager.taskById('job-2')!.status, DownloadStatus.orphaned);
  });

  test(
    'finalizing recovery becomes orphaned instead of retrying post-process',
    () async {
      final request = _request();
      final snapshot = DownloadSubmissionSnapshot(
        snapshotId: 'submission-finalizing',
        jobId: 'job-finalizing',
        groupId: null,
        request: request,
        accountId: 'account-a',
        submittedAt: DateTime.utc(2026, 8, 28),
      );
      final store = MemoryDownloadRecoveryStore();
      await store.upsert(
        DownloadRecoveryRecord(
          jobId: 'job-finalizing',
          dedupeKey: request.dedupeKey,
          snapshot: snapshot,
          owner: const DownloadOutputOwner(
            ownerId: 'output-job-finalizing',
            jobId: 'job-finalizing',
            accountId: 'account-a',
          ),
          status: DownloadStatus.finalizing,
          pendingMediaStoreId: 34,
        ),
      );
      final sinks = _RecoverableSinkFactory([
        const PendingMediaStoreItem(
          id: 34,
          ownerId: 'output-job-finalizing',
          displayName: '900_p0.jpg',
        ),
      ]);
      final manager = DownloadManager(
        transport: _Transport(_Response()),
        sinkFactory: sinks,
        submissionContext: () => _context(),
        recoveryStore: store,
      );
      addTearDown(manager.dispose);
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
      final request = _request(pageIndex: 2);
      final snapshot = DownloadSubmissionSnapshot(
        snapshotId: 'submission-scan',
        jobId: 'job-scan',
        groupId: null,
        request: request,
        accountId: 'account-a',
        submittedAt: DateTime.utc(2026, 8, 28),
      );
      final store = MemoryDownloadRecoveryStore();
      await store.upsert(
        DownloadRecoveryRecord(
          jobId: 'job-scan',
          dedupeKey: request.dedupeKey,
          snapshot: snapshot,
          owner: const DownloadOutputOwner(
            ownerId: 'output-job-scan',
            jobId: 'job-scan',
            accountId: 'account-a',
          ),
          status: DownloadStatus.running,
        ),
      );
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
      final manager = DownloadManager(
        transport: _Transport(_Response()),
        sinkFactory: sinks,
        submissionContext: () => _context(),
        recoveryStore: store,
      );
      addTearDown(manager.dispose);

      final report = await manager.recover();

      expect(sinks.cleaned, ['31:output-job-scan']);
      expect(report.retryableJobIds, ['job-scan']);
      expect(report.orphanedPendingOutputIds, [32, 33]);
      expect(report.cleanupFailedPendingOutputIds, isEmpty);
    },
  );

  test('recovery reports a platform owner-cleanup refusal', () async {
    final request = _request();
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-refused',
      jobId: 'job-refused',
      groupId: null,
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 8, 28),
    );
    final store = MemoryDownloadRecoveryStore();
    await store.upsert(
      DownloadRecoveryRecord(
        jobId: snapshot.jobId,
        dedupeKey: request.dedupeKey,
        snapshot: snapshot,
        owner: const DownloadOutputOwner(
          ownerId: 'output-job-refused',
          jobId: 'job-refused',
          accountId: 'account-a',
        ),
        status: DownloadStatus.running,
        pendingMediaStoreId: 44,
      ),
    );
    final sinks = _RecoverableSinkFactory(const [
      PendingMediaStoreItem(
        id: 44,
        ownerId: 'output-job-refused',
        displayName: '900_p0.jpg',
      ),
    ], cleanupSucceeds: false);
    final manager = DownloadManager(
      transport: _Transport(_Response()),
      sinkFactory: sinks,
      submissionContext: () => _context(),
      recoveryStore: store,
    );
    addTearDown(manager.dispose);

    final report = await manager.recover();

    expect(report.cleanupFailedJobIds, ['job-refused']);
    expect(report.cleanupFailedPendingOutputIds, [44]);
    expect(manager.taskById('job-refused')!.status, DownloadStatus.retryable);
  });

  test(
    'group submission gives every child the same immutable group boundary',
    () {
      final manager = DownloadManager(
        transport: _Transport(_Response(body: const [])),
        sinkFactory: MemorySinkFactory(),
        submissionContext: () => _context(),
      );
      addTearDown(manager.dispose);

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
    final groupId = 'group-restart';
    final firstRequest = _request();
    final secondRequest = _request(pageIndex: 1);
    final firstSnapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-group-1',
      jobId: 'job-group-1',
      groupId: groupId,
      request: firstRequest,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 8, 28),
    );
    final secondSnapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-group-2',
      jobId: 'job-group-2',
      groupId: groupId,
      request: secondRequest,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 8, 28),
    );
    final store = MemoryDownloadRecoveryStore();
    await store.upsert(
      DownloadRecoveryRecord(
        jobId: firstSnapshot.jobId,
        dedupeKey: firstRequest.dedupeKey,
        snapshot: firstSnapshot,
        owner: const DownloadOutputOwner(
          ownerId: 'output-job-group-1',
          jobId: 'job-group-1',
          accountId: 'account-a',
        ),
        status: DownloadStatus.running,
      ),
    );
    await store.upsert(
      DownloadRecoveryRecord(
        jobId: secondSnapshot.jobId,
        dedupeKey: secondRequest.dedupeKey,
        snapshot: secondSnapshot,
        owner: const DownloadOutputOwner(
          ownerId: 'output-job-group-2',
          jobId: 'job-group-2',
          accountId: 'account-a',
        ),
        status: DownloadStatus.succeeded,
        finalUri: 'content://media/external/images/media/2',
      ),
    );
    final manager = DownloadManager(
      transport: _Transport(_Response()),
      sinkFactory: MemorySinkFactory(),
      submissionContext: () => _context(),
      recoveryStore: store,
    );
    addTearDown(manager.dispose);
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

  test('a custom-template file name survives recovery unchanged', () {
    // `{author_id}`/`{w}`/`{h}` come from submission-time metadata that the
    // record never persists; the frozen serialized name must be used.
    final request = DownloadRequest(
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
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-name',
      jobId: 'job-name',
      groupId: null,
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 1),
    );
    final record = DownloadRecoveryRecord(
      jobId: snapshot.jobId,
      dedupeKey: request.dedupeKey,
      snapshot: snapshot,
      owner: DownloadOutputOwner(
        ownerId: 'output-name',
        jobId: snapshot.jobId,
        accountId: snapshot.accountId,
      ),
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
    final request = DownloadRequest(
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
    final snapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-retry',
      jobId: 'job-retry',
      groupId: null,
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 1),
    );
    final record = DownloadRecoveryRecord(
      jobId: snapshot.jobId,
      dedupeKey: request.dedupeKey,
      snapshot: snapshot,
      owner: DownloadOutputOwner(
        ownerId: 'output-retry',
        jobId: snapshot.jobId,
        accountId: snapshot.accountId,
      ),
      status: DownloadStatus.running,
    );
    final store = MemoryDownloadRecoveryStore();
    await store.upsert(
      DownloadRecoveryRecord.fromJson(
        (jsonDecode(jsonEncode(record.toJson())) as Map)
            .cast<String, dynamic>(),
      ),
    );
    final sinkFactory = _NameRecordingSinkFactory();
    final manager = DownloadManager(
      transport: _Transport(
        _Response(
          body: const [
            [1],
          ],
        ),
      ),
      sinkFactory: sinkFactory,
      submissionContext: () => _context(),
      recoveryStore: store,
    );
    addTearDown(manager.dispose);

    await manager.recover();
    expect(manager.taskById('job-retry')!.displayName, '42_100x200_123_p0');

    final retried = manager.retry('job-retry')!;
    await _pumpUntil(
      () => manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
    );

    expect(retried.displayName, '42_100x200_123_p0');
    expect(sinkFactory.names, ['42_100x200_123_p0']);
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
