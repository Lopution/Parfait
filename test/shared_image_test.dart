import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/shared_image.dart';

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

    test('rejects non-images, missing, empty and oversized files', () {
      for (final (path, mimeType) in [
        (write('note.txt').path, 'text/plain'),
        (write('note.zip').path, 'application/zip'),
        ('${tempDir.path}/missing.png', 'image/png'),
        (write('empty.png', size: 0).path, 'image/jpeg'),
        (
          write('huge.png', size: SharedImageValidator.maxBytes + 1).path,
          'image/png',
        ),
      ]) {
        expect(
          () => SharedImageValidator.validate(path: path, mimeType: mimeType),
          throwsA(isA<SharedImageRejected>()),
          reason: path,
        );
      }
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
