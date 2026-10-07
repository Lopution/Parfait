import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/image/disk_image_cache.dart';
import 'package:parfait/core/image/legacy_image_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory support;

  setUp(() {
    final root = Directory.systemTemp.createTempSync('parfait-legacy-');
    addTearDown(() => root.delete(recursive: true));
    temp = Directory(p.join(root.path, 'temp'))..createSync();
    support = Directory(p.join(root.path, 'support'))..createSync();
  });

  File touch(Directory dir, String path) => File(p.join(dir.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  test('the old image files and their index go, nothing else', () async {
    touch(temp, 'parfait_images/abc123.jpg');
    final index = [
      touch(support, 'parfait_images.db'),
      touch(support, 'parfait_images.db-journal'),
      touch(support, 'parfait_images.json'),
    ];
    final kept = [
      touch(temp, '${DiskImageCache.directoryName}/ab/abc123'),
      touch(temp, 'share.png'),
      touch(support, 'logs/crash.log'),
    ];

    final deleted = await deleteLegacyImageCache(temp: temp, support: support);

    expect(deleted, [
      p.join(temp.path, 'parfait_images'),
      for (final file in index) file.path,
    ]);
    expect(
      Directory(p.join(temp.path, 'parfait_images')).existsSync(),
      isFalse,
    );
    expect(index.where((file) => file.existsSync()), isEmpty);
    expect(kept.where((file) => !file.existsSync()), isEmpty);
  });

  test('a launch with nothing left deletes nothing', () async {
    expect(await deleteLegacyImageCache(temp: temp, support: support), isEmpty);
  });
}
