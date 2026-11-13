import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../download/download_recovery.dart';
import '../download/resume_anchor.dart';
import 'android_platform_interfaces.dart';
import 'desktop_file_sink.dart';

/// iOS `MediaStoreSession` backed by `PHPhotoLibrary` over the
/// `parfait/ios_photos` [MethodChannel].
///
/// Streams incoming chunks into a temporary `.part` file under a per-album,
/// per-transfer staging directory and commits into the user's Photo Library on
/// [MediaStoreHandle.finalize].
class IosPhotoLibraryMediaStoreSession
    implements
        MediaStoreSession,
        OwnedMediaStoreSession,
        ResumableFileMediaStoreSession {
  const IosPhotoLibraryMediaStoreSession({
    MethodChannel channel = const MethodChannel('parfait/ios_photos'),
    this.stagingDirectory,
  }) : _channel = channel;

  final MethodChannel _channel;

  /// Injectable staging root for unit tests; defaults to OS temp directory.
  final Future<Directory> Function()? stagingDirectory;

  static const _defaultAlbum = 'Parfait';
  static const _stagingFolder = 'parfait_ios_photos';
  static const _stagedSuffix = '.part';
  static int _nextId = 0;

  Future<Directory> _root() async {
    if (stagingDirectory != null) return stagingDirectory!();
    return getTemporaryDirectory();
  }

  static String _albumOf(String? relativePath) {
    if (relativePath == null || relativePath.trim().isEmpty) {
      return _defaultAlbum;
    }
    final segments = relativePath
        .split(RegExp(r'[/\\]'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.isEmpty) return _defaultAlbum;
    final raw = segments.length == 1 ? segments.first : segments.last;
    return sanitizeDesktopFileName(raw, fallback: _defaultAlbum);
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

  Future<MediaStoreHandle> _open({
    required String displayName,
    required String mimeType,
    String? relativePath,
  }) async {
    final root = await _root();
    final album = _albumOf(relativePath);
    final id = ++_nextId;
    final safeName = sanitizeDesktopFileName(displayName);
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}$_stagingFolder'
      '${Platform.pathSeparator}$album${Platform.pathSeparator}job_$id',
    );
    await dir.create(recursive: true);
    final finalFile = File('${dir.path}${Platform.pathSeparator}$safeName');
    final stagedFile = File('${finalFile.path}$_stagedSuffix');
    if (await stagedFile.exists()) await stagedFile.delete();
    return _IosPhotoStagedHandle(
      id: id,
      finalFile: finalFile,
      stagedFile: stagedFile,
      album: album,
      mimeType: mimeType,
      channel: _channel,
      sink: stagedFile.openWrite(),
    );
  }

  @override
  Future<ResumedPendingItem?> resumePendingPath(String path) async {
    if (!path.endsWith(_stagedSuffix)) return null;
    final stagedFile = File(path);
    if (!await stagedFile.exists()) return null;
    final finalPath = path.substring(0, path.length - _stagedSuffix.length);
    final finalFile = File(finalPath);
    final album = finalFile.parent.parent.uri.pathSegments.lastWhere(
      (s) => s.isNotEmpty,
      orElse: () => _defaultAlbum,
    );
    final storedBytes = await stagedFile.length();
    final handle = _IosPhotoStagedHandle(
      id: ++_nextId,
      finalFile: finalFile,
      stagedFile: stagedFile,
      album: album,
      mimeType: _inferMimeType(finalFile.path),
      channel: _channel,
      sink: stagedFile.openWrite(mode: FileMode.append),
    );
    return ResumedPendingItem(handle: handle, storedBytes: storedBytes);
  }

  static String _inferMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    return 'image/jpeg';
  }
}

class _IosPhotoStagedHandle implements ResumableMediaStoreHandle {
  _IosPhotoStagedHandle({
    required this.id,
    required this.finalFile,
    required this.stagedFile,
    required this.album,
    required this.mimeType,
    required MethodChannel channel,
    required IOSink sink,
  }) : _channel = channel,
       _sink = sink;

  @override
  final int id;
  final File finalFile;
  final File stagedFile;
  final String album;
  final String mimeType;
  final MethodChannel _channel;
  final IOSink _sink;
  bool _closed = false;

  @override
  Future<void> write(List<int> bytes) async {
    _sink.add(bytes);
    await _sink.flush();
  }

  @override
  Future<Uri> finalize() async {
    if (_closed) {
      throw StateError('iOS photo handle $id is already closed');
    }
    _closed = true;
    await _sink.close();
    if (await stagedFile.exists()) {
      await stagedFile.rename(finalFile.path);
    }
    try {
      final result = await _channel.invokeMethod<String>('saveImage', {
        'path': finalFile.path,
        'displayName': finalFile.uri.pathSegments.last,
        'mimeType': mimeType,
        'album': album,
      });
      if (result == null || result.isEmpty) {
        throw StateError('parfait/ios_photos saveImage returned empty URI');
      }
      return Uri.parse(result);
    } finally {
      await _cleanupStagingDir();
    }
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink.close();
    } catch (_) {
      // Cleanup must not mask the original failure.
    }
    await _cleanupStagingDir();
  }

  @override
  ResumeAnchorKind get anchorKind => ResumeAnchorKind.file;

  @override
  Future<String> detach() async {
    if (_closed) throw StateError('iOS photo handle $id is closed');
    _closed = true;
    await _sink.close();
    return stagedFile.path;
  }

  Future<void> _cleanupStagingDir() async {
    try {
      if (await stagedFile.exists()) await stagedFile.delete();
    } catch (_) {}
    try {
      if (await finalFile.exists()) await finalFile.delete();
    } catch (_) {}
    try {
      final dir = finalFile.parent;
      if (await dir.exists() && await dir.list().isEmpty) {
        await dir.delete();
      }
    } catch (_) {}
  }
}
