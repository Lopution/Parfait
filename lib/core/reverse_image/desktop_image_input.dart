import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../platform/app_storage_paths.dart';
import '../platform/shared_image.dart';
import 'image_input.dart';
import 'reverse_image_platform.dart';

/// Desktop [ReverseImageInputPlatform]: `file_selector` opens the native
/// picker and returns a real path, so `contentUri` is a filesystem path and
/// `copyToOwnedFile` is a plain file copy into the temp sandbox.
class DesktopReverseImageInputPlatform implements ReverseImageInputPlatform {
  const DesktopReverseImageInputPlatform({
    Future<XFile?> Function({List<XTypeGroup> acceptedTypeGroups})?
    openFileHandler,
  }) : _openFile = openFileHandler;

  final Future<XFile?> Function({List<XTypeGroup> acceptedTypeGroups})?
  _openFile;

  static const _imageTypes = XTypeGroup(
    label: 'images',
    extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
    mimeTypes: [
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
      'image/bmp',
    ],
    uniformTypeIdentifiers: [
      'public.jpeg',
      'public.png',
      'org.webmproject.webp',
      'com.compuserve.gif',
      'com.microsoft.bmp',
    ],
  );

  static const _mimeByExtension = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
  };

  static String _mimeOf(XFile file) {
    if (file.mimeType != null && file.mimeType!.isNotEmpty) {
      return file.mimeType!;
    }
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    return _mimeByExtension[ext] ?? 'application/octet-stream';
  }

  /// Sniffs a supported image MIME type from encoded magic bytes.
  static ({String mimeType, String extension})? sniffEncodedImage(
    Uint8List bytes,
  ) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return (mimeType: 'image/png', extension: '.png');
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return (mimeType: 'image/jpeg', extension: '.jpg');
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return (mimeType: 'image/gif', extension: '.gif');
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return (mimeType: 'image/webp', extension: '.webp');
    }
    return null;
  }

  /// Builds a validated [ReverseImageInputReference] from a dropped local file
  /// path without mutating or deleting the original file.
  static Future<ReverseImageInputReference> referenceFromFilePath(
    String filePath,
  ) async {
    final file = File(filePath);
    FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'dropped image is not readable',
      );
    }
    if (stat.type != FileSystemEntityType.file) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'dropped path is not a regular file',
      );
    }
    var mimeType =
        _mimeByExtension[p
            .extension(filePath)
            .replaceFirst('.', '')
            .toLowerCase()];
    if (mimeType == null) {
      try {
        final raf = await file.open();
        try {
          final header = await raf.read(16);
          mimeType = sniffEncodedImage(header)?.mimeType;
        } finally {
          await raf.close();
        }
      } on FileSystemException {
        mimeType = null;
      }
    }
    final resolvedMime = mimeType ?? 'application/octet-stream';
    SharedImageValidator.validateMetadata(
      mimeType: resolvedMime,
      sizeBytes: stat.size,
    );
    return ReverseImageInputReference(
      contentUri: filePath,
      mimeType: resolvedMime,
      sizeBytes: stat.size,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );
  }

  /// Stages clipboard image bytes in a temporary file, runs [onReference]
  /// (typically `controller.prepare`), and deletes the staging file in
  /// `finally` so no temporary paste files leak (`REV-01`).
  static Future<void> withStagedClipboardBytes(
    Uint8List bytes,
    Future<void> Function(ReverseImageInputReference reference) onReference,
  ) async {
    final detected = sniffEncodedImage(bytes);
    final mimeType = detected?.mimeType ?? 'application/octet-stream';
    SharedImageValidator.validateMetadata(
      mimeType: mimeType,
      sizeBytes: bytes.length,
    );
    final temp = await AppStoragePaths.active.resolveTempDir();
    final stagingDir = Directory(p.join(temp.path, 'reverse_image'));
    await stagingDir.create(recursive: true);
    final stagingFile = File(
      p.join(
        stagingDir.path,
        'paste_${DateTime.now().microsecondsSinceEpoch}${detected?.extension ?? '.png'}',
      ),
    );
    await stagingFile.writeAsBytes(bytes, flush: true);
    try {
      await onReference(
        ReverseImageInputReference(
          contentUri: stagingFile.path,
          mimeType: mimeType,
          sizeBytes: bytes.length,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.picker,
        ),
      );
    } finally {
      try {
        if (await stagingFile.exists()) {
          await stagingFile.delete();
        }
      } on FileSystemException {
        // Best-effort cleanup of the transient staging file.
      }
    }
  }

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    final file = await (_openFile ?? openFile)(
      acceptedTypeGroups: [_imageTypes],
    );
    if (file == null) return null;
    final mimeType = _mimeOf(file);
    final sizeBytes = await file.length();
    // The same validation the Android channel boundary performs — desktop
    // paths carry no permission grant, so the reference is self-contained.
    SharedImageValidator.validateMetadata(
      mimeType: mimeType,
      sizeBytes: sizeBytes,
    );
    return ReverseImageInputReference(
      contentUri: file.path,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );
  }

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async {
    final source = File(reference.contentUri);
    if (!await source.exists()) {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.copyFailed,
        'picked image no longer exists',
      );
    }
    final temp = await AppStoragePaths.active.resolveTempDir();
    final targetDir = Directory(p.join(temp.path, 'reverse_image'));
    await targetDir.create(recursive: true);
    final target = File(
      p.join(
        targetDir.path,
        'in_${DateTime.now().microsecondsSinceEpoch}${p.extension(source.path)}',
      ),
    );
    await source.copy(target.path);
    return target.path;
  }

  @override
  Future<void> deleteOwnedFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
