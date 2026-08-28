import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/widget/widget_snapshot.dart';

void main() {
  WidgetSnapshot snapshot() => WidgetSnapshot.create(
    accountKey: 'a' * 16,
    accountRevision: 7,
    generatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    items: const [
      WidgetSnapshotItem(
        illustId: 42,
        title: 't',
        userId: 9,
        userName: 'u',
        imageFile: 'cover_42.img',
      ),
    ],
  );

  group('schema', () {
    test('round-trips through encode/parse', () {
      final parsed = WidgetSnapshot.parse(snapshot().encode());
      expect(parsed.schemaVersion, widgetSnapshotSchemaVersion);
      expect(parsed.accountKey, 'a' * 16);
      expect(parsed.accountRevision, 7);
      expect(parsed.generatedAtMs, 1700000000000);
      expect(parsed.items.single.illustId, 42);
      expect(parsed.items.single.imageFile, 'cover_42.img');
    });

    test('parse is strict about field types', () {
      const bad = [
        '{"schemaVersion":"1","accountKey":"k","accountRevision":0,'
            '"generatedAtMs":1,"items":[]}',
        '{"schemaVersion":1,"accountKey":2,"accountRevision":0,'
            '"generatedAtMs":1,"items":[]}',
        '{"schemaVersion":1,"accountKey":"k","accountRevision":"0",'
            '"generatedAtMs":1,"items":[]}',
        '{"schemaVersion":1,"accountKey":"k","accountRevision":0,'
            '"generatedAtMs":"1","items":[]}',
        '{"schemaVersion":1,"accountKey":"","accountRevision":0,'
            '"generatedAtMs":1,"items":[]}',
        'not json at all',
        '[1,2,3]',
      ];
      for (final raw in bad) {
        expect(
          () => WidgetSnapshot.parse(raw),
          throwsA(isA<WidgetSnapshotFormatError>()),
          reason: 'payload must be rejected: $raw',
        );
      }
    });

    test('unknown schema version is not renderable', () {
      final parsed = WidgetSnapshot.parse(
        snapshot().encode().replaceFirst(
          '"schemaVersion":1',
          '"schemaVersion":99',
        ),
      );
      expect(parsed.renderable, isFalse);
    });

    test('empty item list is not renderable', () {
      final empty = WidgetSnapshot.create(
        accountKey: 'k',
        accountRevision: 0,
        generatedAt: DateTime.now(),
        items: const [],
      );
      expect(empty.renderable, isFalse);
    });
  });

  group('item bounds', () {
    test('rejects non-positive ids and path-like image refs', () {
      const bad = [
        <String, Object?>{
          'illustId': 0,
          'title': 't',
          'userId': 1,
          'userName': 'u',
          'imageFile': 'a.img',
        },
        <String, Object?>{
          'illustId': 5,
          'title': 't',
          'userId': 0,
          'userName': 'u',
          'imageFile': 'a.img',
        },
        <String, Object?>{
          'illustId': 5,
          'title': 't',
          'userId': 1,
          'userName': 'u',
          'imageFile': '',
        },
        <String, Object?>{
          'illustId': 5,
          'title': 't',
          'userId': 1,
          'userName': 'u',
          'imageFile': '../secret.img',
        },
        <String, Object?>{
          'illustId': 5,
          'title': 't',
          'userId': 1,
          'userName': 'u',
          'imageFile': 'sub/secret.img',
        },
      ];
      for (final item in bad) {
        expect(
          () => WidgetSnapshotItem.parse(item),
          throwsA(isA<WidgetSnapshotFormatError>()),
        );
      }
    });

    test('snapshot payload contains no URL or credential fields', () {
      final raw = snapshot().encode();
      expect(raw.contains('http'), isFalse);
      expect(raw.contains('token'), isFalse);
      expect(raw.contains('cookie'), isFalse);
    });
  });

  group('age', () {
    test('age reflects generatedAt distance', () {
      final generated = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final later = generated.add(const Duration(hours: 25));
      final parsed = WidgetSnapshot.parse(snapshot().encode());
      expect(parsed.age(later), greaterThan(const Duration(hours: 24)));
    });
  });
}
