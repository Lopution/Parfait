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
}

class _FakeSafDocument implements SafDocumentSink {
  _FakeSafDocument({this.failClose = false});

  final bool failClose;
  @override
  final String uri = 'content://fake/saf/1';
  var closeCalls = 0;
  var deleteCalls = 0;

  @override
  Future<void> write(List<int> bytes) async {}

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
