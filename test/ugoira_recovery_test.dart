import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/download/download_recovery.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/core/platform/android_platform_interfaces.dart';
import 'package:pixiv_func/core/ugoira/ugoira_recovery.dart';

void main() {
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
        credentialRevision: 4,
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
    String displayName,
  ) async => MemorySink();

  @override
  Future<DownloadSink> beginOwned(
    DownloadRequest request,
    String displayName,
    DownloadOutputOwner owner,
  ) => begin(request, displayName);

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
