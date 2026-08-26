import 'dart:io';

/// Validated image payload received through `ACTION_SEND image/*`.
class SharedImage {
  const SharedImage({required this.path, required this.mimeType, required this.sizeBytes});

  final String path;
  final String mimeType;
  final int sizeBytes;
}

class SharedImageRejected implements Exception {
  SharedImageRejected(this.reason);

  final String reason;

  @override
  String toString() => 'SharedImageRejected($reason)';
}

/// Validates an `ACTION_SEND image/*` payload at the Dart boundary.
///
/// The platform layer resolves the content URI into a readable file path;
/// this class enforces the accept/deny rules before anything consumes the
/// image (parent PRD R4 / android-platform-parity R4).
abstract final class SharedImageValidator {
  /// Approximate upper bound for reverse-image-search inputs (10 MB).
  static const int maxBytes = 10 * 1024 * 1024;

  /// Validates and stat's the shared payload.
  ///
  /// Throws [SharedImageRejected] for a non-image MIME type, an unreadable
  /// path or an oversized file.
  static SharedImage validate({
    required String path,
    required String mimeType,
    File? statSource,
  }) {
    if (!mimeType.toLowerCase().startsWith('image/')) {
      throw SharedImageRejected('unsupported MIME type: $mimeType');
    }
    final file = statSource ?? File(path);
    FileStat stat;
    try {
      stat = file.statSync();
    } on FileSystemException catch (error) {
      throw SharedImageRejected('shared image is not readable: ${error.message}');
    }
    if (stat.type == FileSystemEntityType.notFound) {
      throw SharedImageRejected('shared image does not exist');
    }
    final size = stat.size;
    if (size <= 0) {
      throw SharedImageRejected('shared image is empty');
    }
    if (size > maxBytes) {
      throw SharedImageRejected(
          'shared image too large: $size bytes (limit $maxBytes)');
    }
    return SharedImage(path: path, mimeType: mimeType, sizeBytes: size);
  }
}
