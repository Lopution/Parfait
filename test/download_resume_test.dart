import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:pixiv_func/core/download/download_destination.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/core/download/download_transport.dart';
import 'package:pixiv_func/core/download/pixiv_download_transport.dart';
import 'package:pixiv_func/core/platform/android_platform_interfaces.dart';

DownloadRequest _request() => DownloadRequest(
  illustId: 77,
  pageIndex: 0,
  url: Uri.parse('https://i.pximg.net/img-original/img/77_p0.jpg'),
  target: DownloadTarget.illustPage,
);

DownloadSubmissionContext _context() =>
    const DownloadSubmissionContext(accountId: 'account-a');

Future<void> _pumpUntil(bool Function() predicate) async {
  for (var i = 0; i < 500 && !predicate(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Scripted {
  _Scripted({
    this.statusCode = 200,
    this.contentLength,
    this.chunks = const [],
    this.gates,
    this.error,
  });

  final int statusCode;
  final int? contentLength;
  final List<List<int>> chunks;
  final List<Completer<void>>? gates;
  final Object? error;
}

class _Response implements DownloadResponse {
  _Response(this.script, this.cancelToken);

  final _Scripted script;
  final DownloadCancelToken cancelToken;

  @override
  int get statusCode => script.statusCode;

  @override
  int? get contentLength => script.contentLength;

  @override
  Stream<List<int>> get stream {
    final controller = StreamController<List<int>>();
    Future<void> drain() async {
      try {
        for (var i = 0; i < script.chunks.length; i++) {
          if (cancelToken.isCancelled) {
            controller.addError(const DownloadCancelledException());
            await controller.close();
            return;
          }
          final gate = script.gates == null ? null : script.gates![i];
          if (gate != null) await gate.future;
          if (cancelToken.isCancelled) {
            controller.addError(const DownloadCancelledException());
            await controller.close();
            return;
          }
          controller.add(script.chunks[i]);
          await Future<void>.delayed(Duration.zero);
        }
        if (script.error != null) {
          controller.addError(script.error!);
        }
        await controller.close();
      } catch (error) {
        controller.addError(error);
        await controller.close();
      }
    }

    unawaited(drain());
    return controller.stream;
  }

  @override
  Future<void> close() async {}
}

class _Transport implements DownloadTransport {
  final responses = <_Scripted>[];
  final opens = <Map<String, String>>[];

  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async {
    opens.add(Map.of(headers));
    return _Response(responses.removeAt(0), cancelToken);
  }
}

/// Simulated platform layer: committed bytes keyed by locator, mirroring
/// MediaStore pending rows / `.part` files.
class _PlatformStore {
  final files = <String, List<int>>{};
  var nextId = 0;

  String newLocator() => 'part-${nextId++}';
}

class _ResumableSink implements ResumableDownloadSink {
  _ResumableSink(this._store, this.locator) {
    _store.files.putIfAbsent(locator, () => <int>[]);
  }

  final _PlatformStore _store;
  final String locator;
  var _detached = false;
  var _dead = false;
  var aborted = false;

  @override
  int get storedBytes => _store.files[locator]?.length ?? 0;

  @override
  Future<void> write(List<int> bytes) async {
    if (_dead || _detached) throw StateError('sink is closed');
    _store.files[locator]!.addAll(bytes);
  }

  @override
  Future<String> finalize() async {
    if (_dead || _detached) throw StateError('sink is closed');
    _dead = true;
    return 'final://$locator';
  }

  @override
  Future<void> abort() async {
    if (_dead || _detached) return;
    _dead = true;
    aborted = true;
    _store.files.remove(locator);
  }

  @override
  Future<ResumeAnchor?> detach() async {
    if (_dead) throw StateError('sink is closed');
    _detached = true;
    return ResumeAnchor(
      kind: ResumeAnchorKind.file,
      locator: locator,
      storedBytes: storedBytes,
    );
  }
}

class _ResumableFactory
    implements
        DownloadSinkFactory,
        OwnedDownloadSinkFactory,
        ResumableDownloadSinkFactory {
  final store = _PlatformStore();
  final sinks = <_ResumableSink>[];
  var resumeAvailable = true;

  @override
  Future<DownloadSink> begin(
    DownloadRequest request,
    String displayName, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) async {
    final sink = _ResumableSink(store, store.newLocator());
    sinks.add(sink);
    return sink;
  }

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner, {
    DownloadDestination destination = DownloadDestination.builtin,
  }) => begin(request, displayName, destination: destination);

  @override
  Future<DownloadSink?> resumeOwned(
    ResumeAnchor anchor,
    DownloadOutputOwner owner,
  ) async {
    if (!resumeAvailable) return null;
    if (!store.files.containsKey(anchor.locator)) return null;
    final sink = _ResumableSink(store, anchor.locator);
    sinks.add(sink);
    return sink;
  }
}

class _CleanupSpyFactory extends _ResumableFactory
    implements RecoverableDownloadSinkFactory {
  final cleaned = <int>[];

  @override
  Future<List<PendingMediaStoreItem>> listPending() async => const [];

  @override
  Future<bool> cleanupPending(
    int id, {
    required DownloadOutputOwner owner,
  }) async {
    cleaned.add(id);
    return true;
  }
}

void main() {
  installMemoryPreferences();

  group('pause / resume lifecycle (D8)', () {
    test('pause preserves bytes and lands retryable with an anchor', () async {
      final transport = _Transport();
      final factory = _ResumableFactory();
      final gate = Completer<void>();
      transport.responses.add(
        _Scripted(
          contentLength: 30,
          chunks: [List.filled(10, 1), List.filled(10, 2), List.filled(10, 3)],
          gates: [_done(), gate, _done()],
        ),
      );
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: factory,
        submissionContext: _context,
      );
      addTearDown(manager.dispose);

      final task = manager.submit(_request());
      await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
      await manager.pause(task.id);
      gate.complete();
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.retryable,
      );

      final paused = manager.taskById(task.id)!;
      expect(paused.failureKind, DownloadFailureKind.paused);
      expect(paused.resumeAnchor, isNotNull);
      expect(paused.resumeAnchor!.storedBytes, 10);
      expect(factory.sinks.single.aborted, isFalse);
      expect(factory.store.files.values.single, List.filled(10, 1));
    });

    test('retry sends Range and appends on 206', () async {
      final transport = _Transport();
      final factory = _ResumableFactory();
      final gate = Completer<void>();
      transport.responses.add(
        _Scripted(
          contentLength: 30,
          chunks: [List.filled(10, 1), List.filled(10, 2), List.filled(10, 3)],
          gates: [_done(), gate, _done()],
        ),
      );
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: factory,
        submissionContext: _context,
      );
      addTearDown(manager.dispose);

      final task = manager.submit(_request());
      await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
      await manager.pause(task.id);
      gate.complete();
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.retryable,
      );

      transport.responses.add(
        _Scripted(
          statusCode: 206,
          contentLength: 20,
          chunks: [List.filled(10, 2), List.filled(10, 3)],
        ),
      );
      final retried = manager.retry(task.id)!;
      await _pumpUntil(
        () => manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
      );

      expect(transport.opens.last['Range'], 'bytes=10-');
      expect(factory.store.files.values.single, [
        ...List.filled(10, 1),
        ...List.filled(10, 2),
        ...List.filled(10, 3),
      ]);
      final done = manager.taskById(retried.id)!;
      expect(done.receivedBytes, 30);
      expect(done.totalBytes, 30);
      expect(done.resumeAnchor, isNull);
    });

    test(
      'server ignores Range (200) → stale bytes discarded, fresh run',
      () async {
        final transport = _Transport();
        final factory = _ResumableFactory();
        final gate = Completer<void>();
        transport.responses.add(
          _Scripted(
            contentLength: 30,
            chunks: [List.filled(10, 1), List.filled(10, 2)],
            gates: [_done(), gate],
          ),
        );
        final manager = DownloadManager(
          transport: transport,
          sinkFactory: factory,
          submissionContext: _context,
        );
        addTearDown(manager.dispose);

        final task = manager.submit(_request());
        await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
        await manager.pause(task.id);
        gate.complete();
        await _pumpUntil(
          () => manager.taskById(task.id)?.status == DownloadStatus.retryable,
        );

        transport.responses.addAll([
          // The server ignores Range and answers a full body.
          _Scripted(contentLength: 20),
          _Scripted(contentLength: 20, chunks: [List.filled(20, 9)]),
        ]);
        final retried = manager.retry(task.id)!;
        await _pumpUntil(
          () =>
              manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
        );

        // The resumed sink was aborted (stale partial deleted); a fresh sink
        // took the full 200 body.
        expect(factory.sinks[1].aborted, isTrue);
        expect(factory.store.files.values.single, List.filled(20, 9));
        expect(manager.taskById(retried.id)!.receivedBytes, 20);
      },
    );

    test('416 discards the anchor and reopens without Range', () async {
      final transport = _Transport();
      final factory = _ResumableFactory();
      final gate = Completer<void>();
      transport.responses.add(
        _Scripted(
          contentLength: 30,
          chunks: [List.filled(10, 1), List.filled(10, 2)],
          gates: [_done(), gate],
        ),
      );
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: factory,
        submissionContext: _context,
      );
      addTearDown(manager.dispose);

      final task = manager.submit(_request());
      await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
      await manager.pause(task.id);
      gate.complete();
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.retryable,
      );

      transport.responses.addAll([
        _Scripted(statusCode: 416),
        _Scripted(contentLength: 20, chunks: [List.filled(20, 5)]),
      ]);
      final retried = manager.retry(task.id)!;
      await _pumpUntil(
        () => manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
      );

      expect(transport.opens.length, 3);
      expect(transport.opens[1]['Range'], 'bytes=10-');
      expect(transport.opens.last.containsKey('Range'), isFalse);
      expect(factory.store.files.values.single, List.filled(20, 5));
    });

    test('network failure preserves bytes; retry resumes', () async {
      final transport = _Transport();
      final factory = _ResumableFactory();
      transport.responses.add(
        _Scripted(
          contentLength: 30,
          chunks: [List.filled(10, 1)],
          error: const SocketException('connection reset'),
        ),
      );
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: factory,
        submissionContext: _context,
      );
      addTearDown(manager.dispose);

      final task = manager.submit(_request());
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.failed,
      );

      final failed = manager.taskById(task.id)!;
      expect(failed.failureKind, DownloadFailureKind.network);
      expect(failed.resumeAnchor!.storedBytes, 10);
      expect(factory.sinks.single.aborted, isFalse);

      transport.responses.add(
        _Scripted(
          statusCode: 206,
          contentLength: 20,
          chunks: [List.filled(20, 7)],
        ),
      );
      final retried = manager.retry(task.id)!;
      await _pumpUntil(
        () => manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
      );
      expect(transport.opens.last['Range'], 'bytes=10-');
      expect(factory.store.files.values.single.length, 30);
    });

    test(
      'mismatched platform byte count discards anchor, no Range sent',
      () async {
        final transport = _Transport();
        final factory = _ResumableFactory();
        final gate = Completer<void>();
        transport.responses.add(
          _Scripted(
            contentLength: 30,
            chunks: [List.filled(10, 1), List.filled(10, 2)],
            gates: [_done(), gate],
          ),
        );
        final manager = DownloadManager(
          transport: transport,
          sinkFactory: factory,
          submissionContext: _context,
        );
        addTearDown(manager.dispose);

        final task = manager.submit(_request());
        await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
        await manager.pause(task.id);
        gate.complete();
        await _pumpUntil(
          () => manager.taskById(task.id)?.status == DownloadStatus.retryable,
        );
        // External actor truncated the preserved output.
        factory.store.files.values.single.removeLast();

        transport.responses.add(
          _Scripted(contentLength: 30, chunks: [List.filled(30, 4)]),
        );
        final retried = manager.retry(task.id)!;
        await _pumpUntil(
          () =>
              manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
        );

        expect(transport.opens.length, 2);
        expect(transport.opens.last.containsKey('Range'), isFalse);
        expect(factory.store.files.values.single, List.filled(30, 4));
      },
    );

    test('cancel still deletes output even on a resumable sink', () async {
      final transport = _Transport();
      final factory = _ResumableFactory();
      final gate = Completer<void>();
      transport.responses.add(
        _Scripted(
          contentLength: 30,
          chunks: [List.filled(10, 1), List.filled(10, 2)],
          gates: [_done(), gate],
        ),
      );
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: factory,
        submissionContext: _context,
      );
      addTearDown(manager.dispose);

      final task = manager.submit(_request());
      await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
      await manager.cancel(task.id);
      gate.complete();
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.canceled,
      );

      final canceled = manager.taskById(task.id)!;
      expect(canceled.resumeAnchor, isNull);
      expect(factory.sinks.single.aborted, isTrue);
      expect(factory.store.files, isEmpty);
    });

    test('pause on a non-resumable sink still lands retryable', () async {
      final transport = _Transport();
      final sinks = MemorySinkFactory();
      final gate = Completer<void>();
      transport.responses.add(
        _Scripted(
          contentLength: 30,
          chunks: [List.filled(10, 1), List.filled(10, 2)],
          gates: [_done(), gate],
        ),
      );
      final manager = DownloadManager(
        transport: transport,
        sinkFactory: sinks,
        submissionContext: _context,
      );
      addTearDown(manager.dispose);

      final task = manager.submit(_request());
      await _pumpUntil(() => manager.taskById(task.id)?.receivedBytes == 10);
      await manager.pause(task.id);
      gate.complete();
      await _pumpUntil(
        () => manager.taskById(task.id)?.status == DownloadStatus.retryable,
      );

      expect(manager.taskById(task.id)!.resumeAnchor, isNull);
      expect(sinks.sinks.single.aborted, isTrue);

      transport.responses.add(
        _Scripted(contentLength: 30, chunks: [List.filled(30, 8)]),
      );
      final retried = manager.retry(task.id)!;
      await _pumpUntil(
        () => manager.taskById(retried.id)?.status == DownloadStatus.succeeded,
      );
      expect(transport.opens.last.containsKey('Range'), isFalse);
    });
  });

  group('recovery', () {
    test(
      'anchored record keeps its pending row; plain record is cleaned',
      () async {
        final request = _request();
        final snapshot = DownloadSubmissionSnapshot(
          snapshotId: 'submission-1',
          jobId: 'job-1',
          groupId: null,
          request: request,
          accountId: 'account-a',
          submittedAt: DateTime.utc(2026, 9, 20),
        );
        const owner = DownloadOutputOwner(
          ownerId: 'output-job-1',
          jobId: 'job-1',
          accountId: 'account-a',
        );
        const anchor = ResumeAnchor(
          kind: ResumeAnchorKind.mediaStore,
          locator: '17',
          storedBytes: 10,
        );
        final store = MemoryDownloadRecoveryStore();
        await store.upsert(
          DownloadRecoveryRecord(
            jobId: 'job-1',
            dedupeKey: request.dedupeKey,
            snapshot: snapshot,
            owner: owner,
            status: DownloadStatus.running,
            receivedBytes: 10,
            pendingMediaStoreId: 17,
            resumeAnchor: anchor,
          ),
        );
        await store.upsert(
          DownloadRecoveryRecord(
            jobId: 'job-2',
            dedupeKey: '${request.dedupeKey}|x',
            snapshot: snapshot.copyWith(jobId: 'job-2'),
            owner: const DownloadOutputOwner(
              ownerId: 'output-job-2',
              jobId: 'job-2',
              accountId: 'account-a',
            ),
            status: DownloadStatus.running,
            receivedBytes: 10,
            pendingMediaStoreId: 18,
          ),
        );

        final factory = _CleanupSpyFactory();
        final manager = DownloadManager(
          transport: _Transport(),
          sinkFactory: factory,
          submissionContext: _context,
          recoveryStore: store,
        );
        addTearDown(manager.dispose);

        final report = await manager.recover();
        expect(report.retryableJobIds, containsAll(['job-1', 'job-2']));
        // Only the unanchored pending row was cleaned; the anchored row is the
        // resume payload and must survive.
        expect(factory.cleaned, [18]);
        expect(manager.taskById('job-1')!.resumeAnchor, anchor);
      },
    );

    test(
      'record JSON round-trips the anchor; corrupt anchor degrades to null',
      () {
        const anchor = ResumeAnchor(
          kind: ResumeAnchorKind.saf,
          locator: 'content://tree/doc/42.part',
          storedBytes: 64,
        );
        final record = DownloadRecoveryRecord(
          jobId: 'job-x',
          dedupeKey: 'k',
          snapshot: DownloadSubmissionSnapshot(
            snapshotId: 's',
            jobId: 'job-x',
            groupId: null,
            request: _request(),
            accountId: 'account-a',
            submittedAt: DateTime.utc(2026, 9, 20),
          ),
          owner: const DownloadOutputOwner(
            ownerId: 'o',
            jobId: 'job-x',
            accountId: 'account-a',
          ),
          status: DownloadStatus.retryable,
          resumeAnchor: anchor,
        );
        final restored = DownloadRecoveryRecord.fromJson(
          record.toJson().cast<String, dynamic>(),
        );
        expect(restored.resumeAnchor, anchor);

        final corrupt = record.toJson()
          ..['resumeAnchor'] = {'kind': 'mystery', 'locator': 3};
        expect(
          DownloadRecoveryRecord.fromJson(
            corrupt.cast<String, dynamic>(),
          ).resumeAnchor,
          isNull,
        );
      },
    );
  });
}

Completer<void> _done() => Completer<void>()..complete();
