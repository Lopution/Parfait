import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/network/data_worker.dart';

import 'helpers/illust_fixtures.dart';

int _double(int value) => value * 2;

({List<IllustEntity> illusts, String? nextUrl}) _parseIllusts(
  Uint8List bytes,
) => IllustEntity.parsePage(
  jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
);

int _fail(int _) => throw const FormatException('bad page');

RawReceivePort _unsendable(int _) => RawReceivePort();

int _exitIsolate(int _) => Isolate.exit();

void main() {
  group('IsolateDataWorker', () {
    late IsolateDataWorker worker;

    setUp(() => worker = IsolateDataWorker());
    tearDown(() => worker.close());

    test('runs work off the calling isolate and returns its result', () async {
      expect(await worker.run(_double, 21, label: 'double'), 42);
      // Later requests reuse the same isolate.
      expect(await worker.run(_double, 4, label: 'double'), 8);
    });

    test('hands back mapped entities', () async {
      final bytes = utf8.encode(
        jsonEncode({
          'illusts': [illustJson(1), illustJson(2, pageCount: 3)],
          'next_url': null,
        }),
      );
      final page = await worker.run(_parseIllusts, bytes, label: 'page');
      expect([for (final illust in page.illusts) illust.id], [1, 2]);
      expect(page.illusts.last.pageCount, 3);
      expect(page.nextUrl, isNull);
    });

    test('a thrown error arrives as itself', () async {
      await expectLater(
        worker.run(_fail, 0, label: 'fail'),
        throwsA(isA<FormatException>()),
      );
      expect(await worker.run(_double, 1, label: 'double'), 2);
    });

    test('a result that cannot cross isolates fails the request', () async {
      await expectLater(
        worker.run(_unsendable, 0, label: 'port'),
        throwsA(anything),
      );
      expect(await worker.run(_double, 3, label: 'double'), 6);
    });

    test(
      'a dead isolate fails its requests and the next one respawns',
      () async {
        await expectLater(
          worker.run(_exitIsolate, 0, label: 'exit'),
          throwsA(isA<DataWorkerExited>()),
        );
        expect(await worker.run(_double, 5, label: 'double'), 10);
      },
    );

    test('close fails pending work and refuses new work', () async {
      final pending = worker.run(_double, 1, label: 'double');
      await worker.close();
      await expectLater(pending, throwsA(isA<DataWorkerExited>()));
      await expectLater(
        worker.run(_double, 1, label: 'double'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test(
    'InlineDataWorker rejects work the isolate worker could not carry',
    () async {
      final port = RawReceivePort();
      addTearDown(port.close);
      await expectLater(
        const InlineDataWorker().run((int _) => port, 0, label: 'task'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        const InlineDataWorker().run(_unsendable, 0, label: 'result'),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
