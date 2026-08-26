import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/platform/shared_image.dart';

void main() {
  group('SharedImageValidator', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('shared_image_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    File write(String name, {int size = 10}) {
      final file = File('${tempDir.path}/$name');
      file.writeAsBytesSync(List.filled(size, 0x42));
      return file;
    }

    test('accepts a readable image within the size limit', () {
      final file = write('cat.png', size: 128);
      final image = SharedImageValidator.validate(
        path: file.path,
        mimeType: 'image/png',
      );
      expect(image.sizeBytes, 128);
      expect(image.path, file.path);
    });

    test('rejects non-image MIME types', () {
      final file = write('note.txt');
      expect(
        () => SharedImageValidator.validate(
          path: file.path,
          mimeType: 'text/plain',
        ),
        throwsA(isA<SharedImageRejected>()),
      );
      expect(
        () => SharedImageValidator.validate(
          path: file.path,
          mimeType: 'application/zip',
        ),
        throwsA(isA<SharedImageRejected>()),
      );
    });

    test('rejects unreadable and missing paths', () {
      expect(
        () => SharedImageValidator.validate(
          path: '${tempDir.path}/missing.png',
          mimeType: 'image/png',
        ),
        throwsA(isA<SharedImageRejected>()),
      );
    });

    test('rejects empty files', () {
      final file = write('empty.png', size: 0);
      expect(
        () => SharedImageValidator.validate(
          path: file.path,
          mimeType: 'image/jpeg',
        ),
        throwsA(isA<SharedImageRejected>()),
      );
    });

    test('rejects oversized images', () {
      final file = write('huge.png', size: SharedImageValidator.maxBytes + 1);
      expect(
        () => SharedImageValidator.validate(
          path: file.path,
          mimeType: 'image/png',
        ),
        throwsA(isA<SharedImageRejected>()),
      );
    });

    test('accepts an image exactly at the size limit', () {
      final file = write('edge.png', size: SharedImageValidator.maxBytes);
      expect(
        SharedImageValidator.validate(
          path: file.path,
          mimeType: 'image/webp',
        ).sizeBytes,
        SharedImageValidator.maxBytes,
      );
    });
  });
}
