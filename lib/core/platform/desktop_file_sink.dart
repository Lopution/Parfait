import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../download/download_recovery.dart';
import '../download/resume_anchor.dart';
import 'android_platform_interfaces.dart';
import 'saf_tree.dart';

const _windowsReservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Sanitizes a single filename or directory segment for Windows/POSIX filesystems:
/// replaces reserved punctuation & ASCII control chars, strips trailing dots/spaces,
/// avoids empty names / `.` / `..`, and prefixes Windows reserved device names.
String sanitizeDesktopFileName(String rawName, {String fallback = 'download'}) {
  var cleaned = rawName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  cleaned = cleaned.trimLeft();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return fallback;
  }
  final dotIndex = cleaned.indexOf('.');
  final stem = (dotIndex == -1 ? cleaned : cleaned.substring(0, dotIndex))
      .toUpperCase();
  if (_windowsReservedNames.contains(stem)) {
    cleaned = '_$cleaned';
  }
  return cleaned;
}

/// Desktop equivalent of the SAF tree picker: the platform file dialog
/// returns a filesystem path, which plays the role of the opaque tree URI.
/// Download destinations store this string verbatim; on desktop it round-
/// trips into [DesktopSafDocumentSinkFactory].
class DesktopDirectoryPicker implements SafTreePicker {
  const DesktopDirectoryPicker();

  @override
  Future<String?> pickTree() => getDirectoryPath(confirmButtonText: null);
}

/// Desktop [DocumentPicker]: the platform file dialog, then a size check
/// before the file is read.
class DesktopDocumentPicker implements DocumentPicker {
  const DesktopDocumentPicker();

  @override
  Future<PickedDocument?> pickDocument({
    required String label,
    required List<String> extensions,
    required List<String> mimeTypes,
    required int maxBytes,
  }) async {
    final file = await openFile(
      acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
    );
    if (file == null) return null;
    if (await file.length() > maxBytes) {
      throw DocumentTooLargeException(maxBytes);
    }
    return (name: file.name, bytes: await file.readAsBytes());
  }
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
    final safeName = sanitizeDesktopFileName(displayName);
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

  static const _defaultAlbum = 'Parfait';

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
    if (segments.isEmpty) return _defaultAlbum;
    final raw = segments.length == 1 ? segments.first : segments.last;
    return sanitizeDesktopFileName(raw, fallback: _defaultAlbum);
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

/// MethodChannel bridge for macOS App Sandbox security-scoped bookmarks.
const MethodChannel _macosBookmarksChannel = MethodChannel(
  'parfait/macos_bookmarks',
);

/// Desktop directory picker wrapped with macOS security-scoped bookmark
/// persistence. Returns the opaque base64 bookmark token as [pickTree]'s result,
/// throwing explicitly if bookmark creation fails rather than silently falling
/// back to a raw unbookmarked path.
class MacosBookmarkDirectoryPicker implements SafTreePicker {
  const MacosBookmarkDirectoryPicker([
    this._channel = _macosBookmarksChannel,
    this._delegate = const DesktopDirectoryPicker(),
  ]);

  final MethodChannel _channel;
  final SafTreePicker _delegate;

  @override
  Future<String?> pickTree() async {
    final path = await _delegate.pickTree();
    if (path == null) return null;
    final bookmark = await _channel.invokeMethod<String>('saveBookmark', {
      'path': path,
    });
    if (bookmark == null || bookmark.isEmpty) {
      throw StateError('macos saveBookmark returned an empty token');
    }
    return bookmark;
  }
}

/// `SafDocumentSinkFactory` for sandboxed macOS builds where [treeUri] is a
/// base64 security-scoped bookmark string produced by
/// [MacosBookmarkDirectoryPicker]. Opens access via `startAccess` before I/O
/// and pairs every close/abort/detach with `stopAccess`.
class MacosBookmarkSafDocumentSinkFactory
    implements SafDocumentSinkFactory, ResumableSafDocumentFactory {
  const MacosBookmarkSafDocumentSinkFactory([
    this._channel = _macosBookmarksChannel,
  ]);

  final MethodChannel _channel;
  static const _resumePrefix = 'macos-bookmark-v1:';

  Future<String> _startAccess(String bookmark) async {
    if (bookmark.trim().isEmpty) {
      throw StateError('macos security-scoped bookmark is empty');
    }
    final resolvedPath = await _channel.invokeMethod<String>('startAccess', {
      'bookmark': bookmark,
    });
    if (resolvedPath == null || resolvedPath.isEmpty) {
      throw StateError('macos startAccess failed for security-scoped bookmark');
    }
    return resolvedPath;
  }

  Future<void> _stopAccess(String bookmark) async {
    try {
      await _channel.invokeMethod<void>('stopAccess', {'bookmark': bookmark});
    } catch (_) {
      // Best-effort scope release; cleanup must not mask primary errors.
    }
  }

  @override
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    DownloadOutputOwner? owner,
    bool staged = false,
  }) async {
    final directory = await _startAccess(treeUri);
    try {
      final sink = await _StagedFileSink.create(
        directory: directory,
        displayName: displayName,
      );
      return _BookmarkedSafSink(
        inner: sink,
        bookmark: treeUri,
        onRelease: () => _stopAccess(treeUri),
      );
    } catch (_) {
      await _stopAccess(treeUri);
      rethrow;
    }
  }

  @override
  Future<({SafDocumentSink sink, int storedBytes})?> resumeSaf({
    required String uri,
    DownloadOutputOwner? owner,
  }) async {
    if (!uri.startsWith(_resumePrefix)) {
      throw StateError(
        'missing macos security-scoped bookmark in resume locator',
      );
    }
    final decoded = jsonDecode(uri.substring(_resumePrefix.length));
    if (decoded is! Map<String, Object?> ||
        decoded['b'] is! String ||
        decoded['p'] is! String) {
      throw StateError('malformed macos bookmark resume locator');
    }
    final bookmark = decoded['b']! as String;
    final stagedPath = decoded['p']! as String;
    await _startAccess(bookmark);
    try {
      final resumed = await _StagedFileSink.resume(stagedPath);
      if (resumed == null) {
        await _stopAccess(bookmark);
        return null;
      }
      return (
        sink: _BookmarkedSafSink(
          inner: resumed.sink,
          bookmark: bookmark,
          onRelease: () => _stopAccess(bookmark),
        ),
        storedBytes: resumed.storedBytes,
      );
    } catch (_) {
      await _stopAccess(bookmark);
      rethrow;
    }
  }
}

class _BookmarkedSafSink
    implements SafDocumentSink, StagedSafDocument, ResumableSafDocument {
  _BookmarkedSafSink({
    required _StagedFileSink inner,
    required String bookmark,
    required Future<void> Function() onRelease,
  }) : _inner = inner,
       _bookmark = bookmark,
       _onRelease = onRelease;

  final _StagedFileSink _inner;
  final String _bookmark;
  final Future<void> Function() _onRelease;
  bool _released = false;

  Future<void> _releaseOnce() async {
    if (_released) return;
    _released = true;
    await _onRelease();
  }

  @override
  String get uri => _inner.uri;

  @override
  Future<void> write(List<int> bytes) => _inner.write(bytes);

  @override
  Future<void> close() async {
    try {
      await _inner.close();
    } finally {
      await _releaseOnce();
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _inner.delete();
    } finally {
      await _releaseOnce();
    }
  }

  @override
  Future<String> commitStaged() async {
    try {
      return await _inner.commitStaged();
    } finally {
      await _releaseOnce();
    }
  }

  @override
  String get resumeLocator =>
      '${MacosBookmarkSafDocumentSinkFactory._resumePrefix}'
      '${jsonEncode({'b': _bookmark, 'p': _inner.stagedPath})}';

  @override
  Future<void> detachSaf() async {
    try {
      await _inner.detachSaf();
    } finally {
      await _releaseOnce();
    }
  }
}
