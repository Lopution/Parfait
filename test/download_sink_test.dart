import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/platform/saf_tree.dart';

void main() {
  test(
    'SAF finalize failure remains recoverable and deletes the document',
    () async {
      final document = _FakeSafDocument(failClose: true);
      final sink = SafDownloadSink(document, owner: null);

      await expectLater(sink.finalize(), throwsA(isA<StateError>()));
      await sink.abort();

      expect(document.closeCalls, 2);
      expect(document.deleteCalls, 1);
    },
  );

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
