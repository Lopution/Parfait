import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/pixiv_download_transport.dart';
import 'package:parfait/core/download/resume_anchor.dart';
import 'package:parfait/core/platform/android_platform_interfaces.dart';
import 'package:parfait/core/platform/desktop_file_sink.dart';
import 'package:parfait/core/platform/saf_tree.dart';

void main() {
  test(
    'SAF finalize failure remains recoverable and deletes the document',
    () async {
      final document = _FakeSafDocument(failClose: true);
      final sink = SafDownloadSink(document, owner: null);

      await expectLater(sink.finalize(), throwsA(isA<StateError>()));
      await sink.abort();

      expect(document.closeCalls, 1);
      expect(document.deleteCalls, 1);
    },
  );

  test(
    'Desktop staged sinks deduplicate concurrent/sequential collisions and abort without committing',
    () async {
      final dir = await Directory.systemTemp.createTemp('desktop-sink-safety');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final factory = DesktopSafDocumentSinkFactory();

      // P1-6: SafDownloadSink.abort() must never invoke close() (commit) on a
      // desktop staged sink — aborted bytes must vanish completely.
      final abortedDoc = await factory.create(
        treeUri: dir.path,
        displayName: 'aborted.jpg',
        mimeType: 'image/jpeg',
        staged: true,
      );
      final abortedSink = SafDownloadSink(
        abortedDoc,
        owner: null,
        staged: true,
      );
      await abortedSink.write(const [1, 2, 3, 4]);
      await abortedSink.abort();
      expect(dir.listSync(), isEmpty);

      // P0-1: two concurrent downloads with the same filename get distinct
      // `.part` files and distinct committed files; a sequential third never
      // overwrites the first.
      final first = await factory.create(
        treeUri: dir.path,
        displayName: 'untitled.jpg',
        mimeType: 'image/jpeg',
        staged: true,
      );
      final second = await factory.create(
        treeUri: dir.path,
        displayName: 'untitled.jpg',
        mimeType: 'image/jpeg',
        staged: true,
      );
      await first.write(const [10, 11]);
      await second.write(const [20, 21, 22]);
      final uri1 = await (first as StagedSafDocument).commitStaged();
      final uri2 = await (second as StagedSafDocument).commitStaged();
      expect(uri1, isNot(uri2));
      expect(await File.fromUri(Uri.parse(uri1)).readAsBytes(), [10, 11]);
      expect(await File.fromUri(Uri.parse(uri2)).readAsBytes(), [20, 21, 22]);

      final third = await factory.create(
        treeUri: dir.path,
        displayName: 'untitled.jpg',
        mimeType: 'image/jpeg',
        staged: true,
      );
      await third.write(const [30]);
      final uri3 = await (third as StagedSafDocument).commitStaged();
      expect({uri1, uri2, uri3}, hasLength(3));
      expect(await File.fromUri(Uri.parse(uri1)).readAsBytes(), [10, 11]);
      expect(await File.fromUri(Uri.parse(uri3)).readAsBytes(), [30]);
    },
  );

  test('HttpDownloadTransport rejects non-443 HTTPS download ports', () async {
    final transport = HttpDownloadTransport(
      allowedHosts: const {'i.pximg.net'},
      requireHttps: true,
    );
    addTearDown(transport.dispose);
    await expectLater(
      transport.open(
        Uri.parse('https://i.pximg.net:8443/img.jpg'),
        headers: const <String, String>{},
        cancelToken: DownloadCancelToken(),
      ),
      throwsA(isA<DownloadTransportException>()),
    );
  });

  test('SAF abort after finalize does not delete a visible document', () async {
    final document = _FakeSafDocument();
    final sink = SafDownloadSink(document, owner: null);

    expect(await sink.finalize(), document.uri);
    await sink.abort();

    expect(document.closeCalls, 1);
    expect(document.deleteCalls, 0);
  });

  test(
    'SAF coalesces channel writes and flushes the final remainder',
    () async {
      final document = _FakeSafDocument();
      final sink = SafDownloadSink(document, owner: null);

      await sink.write(List<int>.filled(downloadChannelWriteSize - 1, 1));
      expect(document.writes, isEmpty);

      await sink.write([2, 3]);
      expect(document.writes, hasLength(1));
      expect(document.writes.single, hasLength(downloadChannelWriteSize));
      expect(document.writes.single.last, 2);

      await sink.finalize();
      expect(document.writes, hasLength(2));
      expect(document.writes.last, [3]);
    },
  );

  test('SAF abort discards buffered channel writes', () async {
    final document = _FakeSafDocument();
    final sink = SafDownloadSink(document, owner: null);

    await sink.write(List<int>.filled(downloadChannelWriteSize - 1, 1));
    await sink.abort();

    expect(document.writes, isEmpty);
  });

  test('SAF staged finalize renames through commitStaged', () async {
    final document = _FakeStagedSafDocument();
    final sink = SafDownloadSink(document, owner: null, staged: true);

    expect(await sink.finalize(), 'content://fake/saf/renamed');
    expect(document.commitCalls, 1);
  });

  test('SAF staged sink without a renamable document fails visibly', () {
    final sink = SafDownloadSink(_FakeSafDocument(), owner: null, staged: true);
    expect(sink.finalize(), throwsStateError);
  });

  test('SAF detach produces a saf anchor and seals the sink', () async {
    final document = _FakeStagedSafDocument();
    final sink = SafDownloadSink(document, owner: null, staged: true);

    await sink.write([1, 2, 3]);
    final anchor = await sink.detach();

    expect(anchor!.kind, ResumeAnchorKind.saf);
    expect(anchor.locator, document.uri);
    expect(anchor.storedBytes, 3);
    expect(document.detachCalls, 1);

    // Dead sink: abort preserves the detached output, writes throw.
    await sink.abort();
    expect(document.deleteCalls, 0);
    expect(() => sink.write([1]), throwsStateError);
  });

  test('SAF detach refuses a non-resumable document', () async {
    final sink = SafDownloadSink(_FakeSafDocument(), owner: null);
    expect(await sink.detach(), isNull);
  });

  test('MediaStoreSinkFactory resumes an anchor through the session', () async {
    final session = _FakeResumableSession(storedBytes: 42);
    final factory = MediaStoreSinkFactory(session);
    const owner = DownloadOutputOwner(
      ownerId: 'o1',
      jobId: 'j1',
      accountId: 'a1',
    );

    final sink = await factory.resumeOwned(
      const ResumeAnchor(
        kind: ResumeAnchorKind.mediaStore,
        locator: '9',
        storedBytes: 42,
      ),
      owner,
    );

    expect(session.lastResumedId, 9);
    expect(session.lastOwnerId, 'o1');
    expect((sink! as ResumableDownloadSink).storedBytes, 42);
  });

  test('MediaStoreSinkFactory refuses anchors it cannot serve', () async {
    final factory = MediaStoreSinkFactory(_FakeResumableSession());
    const owner = DownloadOutputOwner(
      ownerId: 'o1',
      jobId: 'j1',
      accountId: 'a1',
    );

    // SAF anchors belong to the saf factory path.
    expect(
      await factory.resumeOwned(
        const ResumeAnchor(
          kind: ResumeAnchorKind.saf,
          locator: 'content://doc/1',
          storedBytes: 1,
        ),
        owner,
      ),
      isNull,
    );
    // File anchors need ResumableFileMediaStoreSession, which the fake
    // does not implement.
    expect(
      await factory.resumeOwned(
        const ResumeAnchor(
          kind: ResumeAnchorKind.file,
          locator: '/tmp/x.part',
          storedBytes: 1,
        ),
        owner,
      ),
      isNull,
    );
    // A missing/foreign row is a null refusal from the session itself.
    final session = _FakeResumableSession()..next = null;
    expect(
      await MediaStoreSinkFactory(session).resumeOwned(
        const ResumeAnchor(
          kind: ResumeAnchorKind.mediaStore,
          locator: 'gone',
          storedBytes: 1,
        ),
        owner,
      ),
      isNull,
    );
  });

  test(
    'DestinationAwareSinkFactory routes saf anchors to the saf factory',
    () async {
      final safFactory = _FakeResumableSafFactory();
      final factory = DestinationAwareSinkFactory(
        mediaStore: MediaStoreSinkFactory(_FakeResumableSession()),
        saf: safFactory,
      );
      const owner = DownloadOutputOwner(
        ownerId: 'o1',
        jobId: 'j1',
        accountId: 'a1',
      );

      final sink = await factory.resumeOwned(
        const ResumeAnchor(
          kind: ResumeAnchorKind.saf,
          locator: 'content://doc/1',
          storedBytes: 5,
        ),
        owner,
      );

      expect(safFactory.lastUri, 'content://doc/1');
      expect((sink! as ResumableDownloadSink).storedBytes, 5);
    },
  );

  test('DestinationAwareSinkFactory exposes MediaStore pending rows', () async {
    const item = PendingMediaStoreItem(
      id: 4,
      ownerId: 'o1',
      displayName: 'a.jpg',
    );
    final session = _FakeResumableSession()..pending.add(item);
    final DownloadSinkFactory factory = DestinationAwareSinkFactory(
      mediaStore: MediaStoreSinkFactory(session),
      saf: _FakeResumableSafFactory(),
    );
    final recoverable = factory as RecoverableDownloadSinkFactory;

    expect(await recoverable.listPending(), [item]);
    const owner = DownloadOutputOwner(
      ownerId: 'o1',
      jobId: 'j1',
      accountId: 'a1',
    );
    expect(await recoverable.cleanupPending(4, owner: owner), isTrue);
    expect(session.abortedPending, [(4, 'o1')]);
  });
}

class _FakeSafDocument implements SafDocumentSink {
  _FakeSafDocument({this.failClose = false});

  final bool failClose;
  @override
  final String uri = 'content://fake/saf/1';
  var closeCalls = 0;
  var deleteCalls = 0;
  final writes = <List<int>>[];

  @override
  Future<void> write(List<int> bytes) async {
    writes.add(List<int>.from(bytes));
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (failClose) throw StateError('close failed');
  }

  @override
  Future<void> delete() async {
    deleteCalls++;
  }
}

class _FakeStagedSafDocument extends _FakeSafDocument
    implements StagedSafDocument, ResumableSafDocument {
  var commitCalls = 0;
  var detachCalls = 0;

  @override
  String get resumeLocator => uri;

  @override
  Future<void> detachSaf() async {
    detachCalls++;
    await close();
  }

  @override
  Future<String> commitStaged() async {
    commitCalls++;
    await close();
    return 'content://fake/saf/renamed';
  }
}

class _FakeResumableSession
    implements
        MediaStoreSession,
        ResumableMediaStoreSession,
        RecoverableMediaStoreSession {
  _FakeResumableSession({this.storedBytes = 0});

  final int storedBytes;
  final pending = <PendingMediaStoreItem>[];
  final abortedPending = <(int, String)>[];
  int? lastResumedId;
  String? lastOwnerId;
  ResumedPendingItem? _next;
  bool _hasNext = true;

  set next(ResumedPendingItem? value) {
    _next = value;
    _hasNext = value != null;
  }

  @override
  Future<MediaStoreHandle> begin({
    required String displayName,
    required String mimeType,
    String? relativePath,
  }) => throw UnimplementedError();

  @override
  Future<List<PendingMediaStoreItem>> listPending() async => pending;

  @override
  Future<bool> abortPending(int id, {required String ownerId}) async {
    abortedPending.add((id, ownerId));
    return true;
  }

  @override
  Future<ResumedPendingItem?> resumePending(
    int id, {
    required String ownerId,
  }) async {
    lastResumedId = id;
    lastOwnerId = ownerId;
    if (!_hasNext) return null;
    return _next ??
        ResumedPendingItem(
          handle: _FakeMediaStoreHandle(),
          storedBytes: storedBytes,
        );
  }
}

class _FakeMediaStoreHandle implements MediaStoreHandle {
  @override
  int get id => 9;

  @override
  Future<void> write(List<int> bytes) async {}

  @override
  Future<Uri> finalize() async => Uri.parse('content://media/9');

  @override
  Future<void> abort() async {}
}

class _FakeResumableSafFactory
    implements SafDocumentSinkFactory, ResumableSafDocumentFactory {
  String? lastUri;
  DownloadOutputOwner? lastOwner;

  @override
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
    bool staged = false,
    List<String> subdirectories = const [],
  }) => throw UnimplementedError();

  @override
  Future<({SafDocumentSink sink, int storedBytes})?> resumeSaf({
    required String uri,
    DownloadOutputOwner? owner,
  }) async {
    lastUri = uri;
    lastOwner = owner;
    return (sink: _FakeStagedSafDocument(), storedBytes: 5);
  }
}
