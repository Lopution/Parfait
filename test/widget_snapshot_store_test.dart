import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/widget/widget_snapshot.dart';
import 'package:pixiv_func/core/widget/widget_snapshot_store.dart';

void main() {
  late Directory tempDir;
  late WidgetSnapshotStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('widget_store_test');
    store = WidgetSnapshotStore(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  WidgetSnapshot snapshot(String accountKey, {int revision = 1}) =>
      WidgetSnapshot.create(
        accountKey: accountKey,
        accountRevision: revision,
        generatedAt: DateTime.now(),
        items: const [
          WidgetSnapshotItem(
            illustId: 1,
            title: 't',
            userId: 2,
            userName: 'u',
            imageFile: 'cover_1.img',
          ),
        ],
      );

  WidgetSnapshot twoItemSnapshot(String accountKey) => WidgetSnapshot.create(
    accountKey: accountKey,
    accountRevision: 1,
    generatedAt: DateTime.now(),
    items: const [
      WidgetSnapshotItem(
        illustId: 2,
        title: 't2',
        userId: 3,
        userName: 'u2',
        imageFile: 'cover_2.img',
      ),
      WidgetSnapshotItem(
        illustId: 3,
        title: 't3',
        userId: 4,
        userName: 'u3',
        imageFile: 'cover_3.img',
      ),
    ],
  );

  group('atomic replace', () {
    test('write then read returns the same payload', () async {
      await store.write(snapshot('k1'), {
        'cover_1.img': [1, 2, 3],
      });
      final read = store.read();
      expect(read, isNotNull);
      expect(read!.accountKey, 'k1');
      expect(store.hasImage('cover_1.img'), isTrue);
    });

    test(
      'replacing the pointer keeps the previous state until it flips',
      () async {
        await store.write(snapshot('k1'), {
          'cover_1.img': [1],
        });
        // A crash between image staging and pointer rename must leave the old
        // active snapshot intact: simulate by writing a temp pointer only.
        final tempPointer = File(
          '${tempDir.path}/$widgetSnapshotActiveFile.tmp',
        );
        await tempPointer.writeAsString('{"broken": true');
        expect(store.read()!.accountKey, 'k1');
        await tempPointer.delete();
      },
    );

    test('oversize payload is rejected and nothing is activated', () async {
      expect(
        () => store.write(snapshot('k1'), {
          'cover_1.img': List.filled(widgetImageMaxBytes + 1, 0),
        }),
        throwsA(isA<WidgetSnapshotOversizeError>()),
      );
    });

    test('write rejects a snapshot with a missing image reference', () async {
      expect(
        () => store.write(snapshot('k1'), const {}),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'failed image staging leaves the active generation untouched',
      () async {
        await store.write(snapshot('old'), {
          'cover_1.img': [1],
        });
        await expectLater(
          store.write(twoItemSnapshot('new'), {
            'cover_2.img': [2],
            'cover_3.img': List.filled(widgetImageMaxBytes + 1, 3),
          }),
          throwsA(isA<WidgetSnapshotOversizeError>()),
        );
        expect(store.read()!.accountKey, 'old');
        expect(store.hasImage('cover_1.img'), isTrue);
        expect(store.hasImage('cover_2.img'), isFalse);
      },
    );
  });

  group('corrupt and foreign input', () {
    test('missing pointer reads as absent', () {
      expect(store.read(), isNull);
    });

    test('malformed pointer reads as absent', () async {
      await File(
        '${tempDir.path}/$widgetSnapshotActiveFile',
      ).writeAsString('{not json');
      expect(store.read(), isNull);
    });

    test('oversize pointer reads as absent', () async {
      await File(
        '${tempDir.path}/$widgetSnapshotActiveFile',
      ).writeAsString('x' * (widgetSnapshotMaxBytes + 1));
      expect(store.read(), isNull);
    });

    test('image reference escaping the image dir is not resolved', () async {
      await store.write(snapshot('k1'), {
        'cover_1.img': [1],
      });
      expect(store.resolveImage('../../secret.img'), isNull);
      expect(store.resolveImage('sub/dir.img'), isNull);
      expect(store.resolveImage(''), isNull);
    });
  });

  group('account switch', () {
    test(
      'clear removes pointer and images so no old account renders',
      () async {
        await store.write(snapshot('old'), {
          'cover_1.img': [1],
        });
        await store.clear();
        expect(store.read(), isNull);
        expect(store.hasImage('cover_1.img'), isFalse);
        // The directory is reusable after clearing.
        await store.write(snapshot('new'), {
          'cover_1.img': [2],
        });
        expect(store.read()!.accountKey, 'new');
      },
    );
  });
}
