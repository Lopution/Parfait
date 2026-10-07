import 'dart:io';

import 'package:path/path.dart' as p;

import '../logging/crash_log.dart';

/// The cache key of the image cache that preceded the image worker: its
/// files sat in `<temp>/parfait_images/`, its index in app support — a
/// SQLite database (plus any journal) on Android, a JSON file on desktop.
const _legacyKey = 'parfait_images';

const _legacyIndexSuffixes = [
  '.db',
  '.db-journal',
  '.db-wal',
  '.db-shm',
  '.json',
];

/// Deletes what the pre-worker image cache left on disk and returns the
/// paths it deleted. Each item is checked and deleted on its own: one that
/// fails goes to the crash log and the rest still go. The worker's cache
/// has another name and is never touched.
Future<List<String>> deleteLegacyImageCache({
  required Directory temp,
  required Directory support,
}) async {
  final targets = <FileSystemEntity>[
    Directory(p.join(temp.path, _legacyKey)),
    for (final suffix in _legacyIndexSuffixes)
      File(p.join(support.path, '$_legacyKey$suffix')),
  ];
  final deleted = <String>[];
  for (final target in targets) {
    try {
      if (!await target.exists()) continue;
      await target.delete(recursive: true);
      deleted.add(target.path);
    } on FileSystemException catch (error, stack) {
      CrashLog.record(error, stack);
    }
  }
  return deleted;
}
