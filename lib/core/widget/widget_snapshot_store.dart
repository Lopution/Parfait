import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'widget_snapshot.dart';

/// Byte ceiling for one snapshot file; anything larger is treated as
/// corrupt and cleared rather than rendered.
const int widgetSnapshotMaxBytes = 64 * 1024;

/// Name of the pointer file native readers consume.
const String widgetSnapshotActiveFile = 'active.json';

/// Where widget render state lives: `filesDir/support/widget_snapshot` on
/// Android. Native code resolves the same location independently.
Future<Directory> widgetSnapshotDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory(
    p.join(support.path, 'widget_snapshot'),
  ).create(recursive: true);
}

/// Owns the secret-free widget render state on disk.
///
/// Layout inside [directory]:
/// - `active.json` — atomically replaced pointer consumed by native.
/// - `images/` — controlled image files referenced by name from the pointer.
///
/// Every write is a temp-file + rename, so a crash or process death can
/// never leave a half-written snapshot behind.
class WidgetSnapshotStore {
  WidgetSnapshotStore(this.directory);

  /// Production store rooted at the app-support widget directory.
  static Future<WidgetSnapshotStore> standard() async =>
      WidgetSnapshotStore(await widgetSnapshotDirectory());

  final Directory directory;

  Directory get _imagesDir => Directory(p.join(directory.path, 'images'));

  File get _activeFile =>
      File(p.join(directory.path, widgetSnapshotActiveFile));

  File get _lockFile => File(p.join(directory.path, '.write.lock'));

  /// Writes [snapshot] and its images atomically. The pointer is replaced
  /// last: until it flips, readers keep the previous consistent state.
  Future<void> write(
    WidgetSnapshot snapshot,
    Map<String, List<int>> images,
  ) async {
    await directory.create(recursive: true);
    final lock = await _lockFile.open(mode: FileMode.append);
    try {
      await lock.lock();
      await _writeLocked(snapshot, images);
    } finally {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  Future<void> _writeLocked(
    WidgetSnapshot snapshot,
    Map<String, List<int>> images,
  ) async {
    final expectedImages = snapshot.items.map((item) => item.imageFile).toSet();
    if (!snapshot.renderable ||
        expectedImages.length != images.length ||
        !expectedImages.every(images.containsKey)) {
      throw const WidgetSnapshotWriteError(
        'snapshot is not renderable or image references do not match supplied images',
      );
    }
    for (final name in images.keys) {
      if (!_isSafeFileName(name)) {
        throw WidgetSnapshotWriteError('unsafe image file name: $name');
      }
    }
    final encoded = snapshot.encode();
    final encodedBytes = utf8.encode(encoded);
    if (encodedBytes.length > widgetSnapshotMaxBytes) {
      throw const WidgetSnapshotOversizeError('snapshot');
    }

    await _imagesDir.create(recursive: true);
    final tempToken =
        '${DateTime.now().microsecondsSinceEpoch}_${Object().hashCode}';
    final temporaryFiles = <File>[];
    // Stage everything under unique temporary names first. Image names are
    // generation-specific in the loader, and refusing an existing final name
    // prevents a writer from mutating files still referenced by the active
    // pointer.
    final stagedFiles = <File>[];
    var pointerPublished = false;
    final tempPointer = File(
      p.join(directory.path, '.$tempToken-$widgetSnapshotActiveFile.tmp'),
    );
    try {
      for (final entry in images.entries) {
        if (entry.value.isEmpty || entry.value.length > widgetImageMaxBytes) {
          throw WidgetSnapshotOversizeError(entry.key);
        }
        final finalPath = p.join(_imagesDir.path, entry.key);
        if (File(finalPath).existsSync()) {
          throw WidgetSnapshotWriteError(
            'image file already belongs to an active generation: ${entry.key}',
          );
        }
        final temp = File(
          p.join(_imagesDir.path, '.$tempToken-${entry.key}.tmp'),
        );
        temporaryFiles.add(temp);
        await temp.writeAsBytes(entry.value, flush: true);
        await temp.rename(finalPath);
        stagedFiles.add(File(finalPath));
      }
      await tempPointer.writeAsBytes(encodedBytes, flush: true);
      await tempPointer.rename(_activeFile.path);
      pointerPublished = true;
    } finally {
      for (final temp in temporaryFiles) {
        if (temp.existsSync()) await temp.delete();
      }
      if (!pointerPublished) {
        for (final staged in stagedFiles) {
          if (staged.existsSync()) await staged.delete();
        }
      }
      if (tempPointer.existsSync()) await tempPointer.delete();
    }

    // Cleanup is deliberately after the pointer flip. A cleanup failure must
    // not turn a successfully published snapshot into a transient result;
    // the orphan can be retried on the next generation without compromising
    // the active pointer or its image set.
    try {
      await _removeUnreferencedImages(expectedImages);
    } on FileSystemException catch (error) {
      stderr.writeln(
        'WidgetSnapshotStore cleanup unavailable: ${error.message}',
      );
    }
  }

  /// Reads the active snapshot. Any problem (missing file, oversize,
  /// malformed JSON, unknown schema) returns null so callers render the
  /// explicit open-app state instead of partial data.
  WidgetSnapshot? read() {
    final File file = _activeFile;
    if (!file.existsSync()) return null;
    final int length = file.lengthSync();
    if (length > widgetSnapshotMaxBytes) return null;
    final String raw;
    try {
      raw = file.readAsStringSync();
    } on FileSystemException {
      return null;
    }
    try {
      return WidgetSnapshot.parse(raw);
    } on WidgetSnapshotFormatError {
      return null;
    }
  }

  /// True when the named image exists inside the controlled image dir.
  bool hasImage(String fileName) =>
      _isSafeFileName(fileName) &&
      File(p.join(_imagesDir.path, fileName)).existsSync();

  /// Resolves a controlled image reference to a readable file, or null.
  File? resolveImage(String fileName) {
    if (!hasImage(fileName)) return null;
    final file = File(p.join(_imagesDir.path, fileName));
    if (file.lengthSync() > widgetImageMaxBytes || file.lengthSync() == 0) {
      return null;
    }
    return file;
  }

  /// Removes pointer and images. Used on logout, account switch and
  /// reauth-required so no previous account's artwork stays renderable.
  Future<void> clear() async {
    if (!directory.existsSync()) return;
    final lock = await _lockFile.open(mode: FileMode.append);
    try {
      await lock.lock();
      if (_activeFile.existsSync()) _activeFile.deleteSync();
      if (directory.existsSync()) {
        await for (final entity in directory.list()) {
          if (entity is File &&
              entity.path != _activeFile.path &&
              entity.path != _lockFile.path) {
            await entity.delete();
          }
        }
      }
      final images = _imagesDir;
      if (images.existsSync()) {
        await for (final entity in images.list()) {
          await entity.delete(recursive: true);
        }
      }
    } finally {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  Future<void> _removeUnreferencedImages(Set<String> activeNames) async {
    if (!_imagesDir.existsSync()) return;
    await for (final entity in _imagesDir.list()) {
      if (entity is! File) continue;
      if (!activeNames.contains(p.basename(entity.path))) {
        await entity.delete();
      }
    }
  }

  static bool _isSafeFileName(String fileName) =>
      fileName.isNotEmpty &&
      fileName != '.' &&
      fileName != '..' &&
      !fileName.contains('/') &&
      !fileName.contains('\\') &&
      !fileName.contains('..');
}

/// Raised when a snapshot payload or image exceeds its byte budget.
class WidgetSnapshotOversizeError implements Exception {
  const WidgetSnapshotOversizeError(this.name);

  final String name;

  @override
  String toString() => 'WidgetSnapshotOversizeError($name)';
}

/// Raised when a generation cannot be published without invalidating the
/// currently active pointer or violating the snapshot contract.
class WidgetSnapshotWriteError implements Exception {
  const WidgetSnapshotWriteError(this.reason);

  final String reason;

  @override
  String toString() => 'WidgetSnapshotWriteError($reason)';
}

/// Byte ceiling for one widget cover image file.
const int widgetImageMaxBytes = 1024 * 1024;
