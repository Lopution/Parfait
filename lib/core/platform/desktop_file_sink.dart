import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../download/download_recovery.dart';
import 'android_platform_interfaces.dart';
import 'saf_tree.dart';

/// Desktop equivalent of the SAF tree picker: the platform file dialog
/// returns a filesystem path, which plays the role of the opaque tree URI.
/// Download destinations store this string verbatim; on desktop it round-
/// trips into [DesktopSafDocumentSinkFactory].
class DesktopDirectoryPicker implements SafTreePicker {
  const DesktopDirectoryPicker();

  @override
  Future<String?> pickTree() => getDirectoryPath(confirmButtonText: null);
}

/// Streaming file sink that stages into `<name>.part` and only materialises
/// the final file on commit — the desktop equivalent of MediaStore's
/// pending-row semantics (a crashed or aborted transfer never leaves a
/// half-written file under the final name).
class _StagedFileSink implements SafDocumentSink, MediaStoreHandle {
  _StagedFileSink._(this._file, this._id);

  static int _nextId = 0;

  static Future<_StagedFileSink> create({
    required String directory,
    required String displayName,
  }) async {
    final safeName = displayName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dir = Directory(directory);
    await dir.create(recursive: true);
    final target = File('${dir.path}${Platform.pathSeparator}$safeName');
    // A stale .part from a crashed run belongs to a dead session — replacing
    // it is the same contract as MediaStore aborting a pending row.
    final staged = File('${target.path}.part');
    if (await staged.exists()) await staged.delete();
    final file = _StagedFileSink._(target, ++_nextId);
    file._sink = staged.openWrite();
    return file;
  }

  final File _file;
  final int _id;
  late final IOSink _sink;
  bool _closed = false;

  /// Staged path carrying the pending bytes until [finalize].
  String get stagedPath => '${_file.path}.part';

  // SafDocumentSink / MediaStoreHandle ------------------------------------------------

  @override
  int get id => _id;

  @override
  String get uri => Uri.file(_file.path).toString();

  @override
  Future<void> write(List<int> bytes) async {
    _sink.add(bytes);
    await _sink.flush();
  }

  /// SAF variant: commit by closing and renaming the staged file.
  @override
  Future<void> close() => _commit();

  /// MediaStore variant: commit and report the final location.
  @override
  Future<Uri> finalize() async {
    await _commit();
    return Uri.file(_file.path);
  }

  /// SAF variant of [abort].
  @override
  Future<void> delete() => _abort();

  /// MediaStore variant of [delete].
  @override
  Future<void> abort() => _abort();

  Future<void> _commit() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
    final staged = File(stagedPath);
    if (await staged.exists()) {
      await staged.rename(_file.path);
    }
  }

  Future<void> _abort() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink.close();
    } catch (_) {
      // Cleanup must not mask the original failure.
    }
    try {
      await File(stagedPath).delete();
    } catch (_) {}
  }
}

/// `SafDocumentSinkFactory` for desktop: `treeUri` is a filesystem directory
/// path chosen through [DesktopDirectoryPicker].
class DesktopSafDocumentSinkFactory implements SafDocumentSinkFactory {
  const DesktopSafDocumentSinkFactory();

  @override
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
  }) {
    return _StagedFileSink.create(directory: treeUri, displayName: displayName);
  }
}

/// `MediaStoreSession` for desktop: writes into the user's Downloads folder
/// (fallback: application support). `relativePath` keeps its Android meaning
/// of "album subdirectory" — `Pictures/<album>` maps to `<base>/<album>`.
class DesktopFileMediaStoreSession
    implements MediaStoreSession, OwnedMediaStoreSession {
  const DesktopFileMediaStoreSession({this.baseDirectory});

  /// Injectable for tests; defaults to the OS Downloads directory.
  final Future<Directory> Function()? baseDirectory;

  static const _defaultAlbum = 'PixivFunc';

  Future<Directory> _base() async {
    if (baseDirectory != null) return baseDirectory!();
    return await getDownloadsDirectory() ??
        await getApplicationSupportDirectory();
  }

  String _albumOf(String? relativePath) {
    if (relativePath == null || relativePath.trim().isEmpty) {
      return _defaultAlbum;
    }
    // Drop the platform root segment (`Pictures`) and keep the album name.
    final segments = relativePath
        .split(RegExp(r'[/\\]'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    return segments.isEmpty
        ? _defaultAlbum
        : (segments.length == 1 ? segments.first : segments.last);
  }

  Future<MediaStoreHandle> _open({
    required String displayName,
    required String mimeType,
    String? relativePath,
  }) async {
    final base = await _base();
    final directory =
        '${base.path}${Platform.pathSeparator}${_albumOf(relativePath)}';
    return _StagedFileSink.create(
      directory: directory,
      displayName: displayName,
    );
  }

  @override
  Future<MediaStoreHandle> begin({
    required String displayName,
    required String mimeType,
    String? relativePath,
  }) => _open(
    displayName: displayName,
    mimeType: mimeType,
    relativePath: relativePath,
  );

  @override
  Future<MediaStoreHandle> beginOwned({
    required String displayName,
    required String mimeType,
    required DownloadOutputOwner owner,
    String? relativePath,
  }) => _open(
    displayName: displayName,
    mimeType: mimeType,
    relativePath: relativePath,
  );
}
