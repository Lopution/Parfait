import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/shared_image.dart';
import 'image_input.dart';
import 'reverse_image_platform.dart';

/// Desktop [ReverseImageInputPlatform]: `file_selector` opens the native
/// picker and returns a real path, so `contentUri` is a filesystem path and
/// `copyToOwnedFile` is a plain file copy into the temp sandbox.
class DesktopReverseImageInputPlatform implements ReverseImageInputPlatform {
  const DesktopReverseImageInputPlatform();

  static const _imageTypes = XTypeGroup(
    label: 'images',
    extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
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

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    final file = await openFile(acceptedTypeGroups: [_imageTypes]);
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
    final temp = await getTemporaryDirectory();
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
