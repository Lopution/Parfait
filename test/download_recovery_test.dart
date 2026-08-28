import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/core/download/download_transport.dart';
import 'package:pixiv_func/core/download/pixiv_download_transport.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/platform/android_platform_interfaces.dart';

DownloadRequest _request({int pageIndex = 0}) => DownloadRequest(
  illustId: 900,
  pageIndex: pageIndex,
  url: Uri.parse('https://i.pximg.net/img-original/img/900_p$pageIndex.jpg'),
  target: DownloadTarget.illustPage,
);

DownloadSubmissionContext _context({
  String accountId = 'account-a',
  int credentialRevision = 3,
  NetworkRevision networkRevision = const NetworkRevision(
    7,
    networkIdentity: 'wifi',
  ),
}) => DownloadSubmissionContext(
  accountId: accountId,
  credentialRevision: credentialRevision,
  networkRevision: networkRevision,
);

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
    String displayName,
  ) async => sink;
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
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = SharedPreferencesAsync();
      final store = PreferencesDownloadRecoveryStore(preferences: preferences);
      final request = _request();
      final snapshot = DownloadSubmissionSnapshot(
        snapshotId: 'submission-round-trip',
        jobId: 'job-round-trip',
        groupId: null,
        request: request,
        accountId: 'account-a',
        credentialRevision: 3,
        networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
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
      credentialRevision: 3,
      networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
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
        credentialRevision: 3,
        networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
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
        credentialRevision: 3,
        networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
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
      credentialRevision: 3,
      networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
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
      credentialRevision: 3,
      networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
      submittedAt: DateTime.utc(2026, 8, 28),
    );
    final secondSnapshot = DownloadSubmissionSnapshot(
      snapshotId: 'submission-group-2',
      jobId: 'job-group-2',
      groupId: groupId,
      request: secondRequest,
      accountId: 'account-a',
      credentialRevision: 3,
      networkRevision: const NetworkRevision(7, networkIdentity: 'wifi'),
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
}
