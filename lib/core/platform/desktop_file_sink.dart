import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../download/download_recovery.dart';
import '../download/resume_anchor.dart';
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
class _StagedFileSink
    implements
        SafDocumentSink,
        MediaStoreHandle,
        ResumableMediaStoreHandle,
        StagedSafDocument,
        ResumableSafDocument {
  _StagedFileSink._(this._file, this._id);

  static int _nextId = 0;
  static const _stagedSuffix = '.part';

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

  /// Reopens a detached `.part` for appending (D8). Returns null when the
  /// staged file is missing or the locator is not a `.part` path — the
  /// caller discards the anchor and begins fresh.
  static Future<({_StagedFileSink sink, int storedBytes})?> resume(
    String stagedPath,
  ) async {
    if (!stagedPath.endsWith(_stagedSuffix)) return null;
    final staged = File(stagedPath);
    if (!await staged.exists()) return null;
    final finalPath = stagedPath.substring(
      0,
      stagedPath.length - _stagedSuffix.length,
    );
    final storedBytes = await staged.length();
    final sink = _StagedFileSink._(File(finalPath), ++_nextId);
    sink._sink = staged.openWrite(mode: FileMode.append);
    return (sink: sink, storedBytes: storedBytes);
  }

  final File _file;
  final int _id;
  late final IOSink _sink;
  bool _closed = false;

  /// Staged path carrying the pending bytes until [finalize].
  String get stagedPath => '${_file.path}$_stagedSuffix';

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

  /// Staged SAF variant: commit by closing and renaming `.part` → final.
  @override
  Future<String> commitStaged() async {
    await _commit();
    return uri;
  }

  /// SAF variant of [abort].
  @override
  Future<void> delete() => _abort();

  /// MediaStore variant of [delete].
  @override
  Future<void> abort() => _abort();

  // D8 resume plumbing ------------------------------------------------------

  @override
  ResumeAnchorKind get anchorKind => ResumeAnchorKind.file;

  /// The locator a later [resume] call needs: the staged `.part` path.
  @override
  String get resumeLocator => stagedPath;

  /// Closes the stream preserving the staged `.part` file — the desktop
  /// equivalent of MediaStore's detached pending row. Afterwards the sink
  /// is dead: `_commit`/`_abort` early-return on `_closed`, so cleanup can
  /// never delete the preserved bytes.
  @override
  Future<String> detach() async {
    if (_closed) throw StateError('sink is closed');
    _closed = true;
    await _sink.close();
    return stagedPath;
  }

  /// SAF variant of [detach]: same stream close, locator stays stagedPath.
  @override
  Future<void> detachSaf() => detach();

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
class DesktopSafDocumentSinkFactory
    implements SafDocumentSinkFactory, ResumableSafDocumentFactory {
  const DesktopSafDocumentSinkFactory();

  /// `staged` is accepted for interface parity; every desktop document is
  /// staged into `<name>.part` internally regardless.
  @override
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
    bool staged = false,
  }) {
    return _StagedFileSink.create(directory: treeUri, displayName: displayName);
  }

  /// [uri] is the opaque locator emitted by [ResumableSafDocument.resumeLocator]
  /// — a raw `.part` filesystem path on desktop.
  @override
  Future<({SafDocumentSink sink, int storedBytes})?> resumeSaf({
    required String uri,
    DownloadOutputOwner? owner,
  }) async {
    final resumed = await _StagedFileSink.resume(uri);
    if (resumed == null) return null;
    return (sink: resumed.sink, storedBytes: resumed.storedBytes);
  }
}

/// `MediaStoreSession` for desktop: writes into the user's Downloads folder
/// (fallback: application support). `relativePath` keeps its Android meaning
/// of "album subdirectory" — `Pictures/<album>` maps to `<base>/<album>`.
class DesktopFileMediaStoreSession
    implements
        MediaStoreSession,
        OwnedMediaStoreSession,
        ResumableFileMediaStoreSession {
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

  @override
  Future<ResumedPendingItem?> resumePendingPath(String path) async {
    final resumed = await _StagedFileSink.resume(path);
    if (resumed == null) return null;
    return ResumedPendingItem(
      handle: resumed.sink,
      storedBytes: resumed.storedBytes,
    );
  }
}
