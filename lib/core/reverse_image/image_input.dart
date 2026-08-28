import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// The two supported entry points intentionally share one prepared-file
/// contract before a provider can see any image data.
enum ReverseImageInputSource { picker, androidSend }

enum ReverseImageFormat { png, jpeg, gif, webp }

/// Conservative limits for an untrusted image. Header parsing is bounded and
/// never decodes the complete image on the UI isolate.
abstract final class ReverseImageInputLimits {
  static const maxEncodedBytes = 10 * 1024 * 1024;
  static const maxHeaderBytes = 64 * 1024;
  static const maxDimension = 8192;
  static const maxDecodedPixels = 16 * 1024 * 1024;
}

/// Metadata received from the Android picker or ACTION_SEND bridge. The
/// content URI is opaque and is copied only by the platform adapter.
@immutable
class ReverseImageInputReference {
  const ReverseImageInputReference({
    required this.contentUri,
    required this.mimeType,
    required this.sizeBytes,
    required this.hasReadUriPermission,
    required this.source,
  });

  final String contentUri;
  final String mimeType;
  final int sizeBytes;
  final bool hasReadUriPermission;
  final ReverseImageInputSource source;
}

enum ReverseImageInputFailureCode {
  invalidReference,
  missingReadPermission,
  invalidMimeType,
  empty,
  oversized,
  unreadable,
  unsupportedFormat,
  malformedFormat,
  mimeMismatch,
  dimensionsTooLarge,
  pixelBudgetExceeded,
  closed,
  cleanupFailed,
}

/// Input errors deliberately contain no path, URI, image bytes or provider
/// response. They are safe to surface in a snackbar and bounded diagnostics.
class ReverseImageInputException implements Exception {
  const ReverseImageInputException(this.code, this.message);

  final ReverseImageInputFailureCode code;
  final String message;

  @override
  String toString() => 'ReverseImageInputException($code, $message)';
}

@immutable
class ReverseImageInputInfo {
  const ReverseImageInputInfo({
    required this.path,
    required this.source,
    required this.mimeType,
    required this.sizeBytes,
    required this.format,
    required this.width,
    required this.height,
  });

  final String path;
  final ReverseImageInputSource source;
  final String mimeType;
  final int sizeBytes;
  final ReverseImageFormat format;
  final int width;
  final int height;
}

/// One temporary file owned by one reverse-image flow. The delete callback is
/// injected so the Android adapter can enforce its private cache boundary and
/// tests can assert exactly-once cleanup.
class OwnedReverseImageInput {
  OwnedReverseImageInput._(this.info, this._delete);

  final ReverseImageInputInfo info;
  final Future<void> Function(String path) _delete;
  bool _disposed = false;

  static Future<OwnedReverseImageInput> open({
    required String path,
    required ReverseImageInputSource source,
    required String mimeType,
    required Future<void> Function(String path) delete,
  }) async {
    try {
      final info = await ReverseImageInputValidator.validateFile(
        path: path,
        source: source,
        mimeType: mimeType,
      );
      return OwnedReverseImageInput._(info, delete);
    } on ReverseImageInputException {
      try {
        await delete(path);
      } on Object {
        throw const ReverseImageInputException(
          ReverseImageInputFailureCode.cleanupFailed,
          'temporary image cleanup failed',
        );
      }
      rethrow;
    }
  }

  /// Opens a streaming read only while this owned input is alive.
  Stream<List<int>> openRead() {
    if (_disposed) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.closed,
        'temporary image is closed',
      );
    }
    return File(info.path).openRead();
  }

  /// Exactly-once cleanup. A cleanup error remains visible to the caller; it
  /// is never converted into a successful search result.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _delete(info.path);
    } on Object {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.cleanupFailed,
        'temporary image cleanup failed',
      );
    }
  }
}

abstract final class ReverseImageInputValidator {
  static Future<ReverseImageInputInfo> validateFile({
    required String path,
    required ReverseImageInputSource source,
    required String mimeType,
  }) async {
    final normalizedMime = mimeType.trim().toLowerCase();
    if (!isSupportedMime(normalizedMime)) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.invalidMimeType,
        'image MIME type is not supported',
      );
    }

    final file = File(path);
    FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'selected image is not readable',
      );
    }
    if (stat.type != FileSystemEntityType.file) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'selected image is not a regular file',
      );
    }
    if (stat.size <= 0) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.empty,
        'selected image is empty',
      );
    }
    if (stat.size > ReverseImageInputLimits.maxEncodedBytes) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.oversized,
        'selected image exceeds the size limit',
      );
    }

    final header = await _readHeader(file);
    final parsed = _ImageHeaderParser.parse(header);
    if (!_mimeMatches(normalizedMime, parsed.format)) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.mimeMismatch,
        'declared image MIME does not match its bytes',
      );
    }
    if (parsed.width > ReverseImageInputLimits.maxDimension ||
        parsed.height > ReverseImageInputLimits.maxDimension) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.dimensionsTooLarge,
        'image dimensions exceed the limit',
      );
    }
    final pixels = parsed.width * parsed.height;
    if (pixels > ReverseImageInputLimits.maxDecodedPixels) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.pixelBudgetExceeded,
        'image pixel budget is too large',
      );
    }
    return ReverseImageInputInfo(
      path: path,
      source: source,
      mimeType: normalizedMime,
      sizeBytes: stat.size,
      format: parsed.format,
      width: parsed.width,
      height: parsed.height,
    );
  }

  static bool isSupportedMime(String mime) => const {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  }.contains(mime);

  static bool _mimeMatches(String mime, ReverseImageFormat format) =>
      switch (format) {
        ReverseImageFormat.png => mime == 'image/png',
        ReverseImageFormat.jpeg => mime == 'image/jpeg',
        ReverseImageFormat.gif => mime == 'image/gif',
        ReverseImageFormat.webp => mime == 'image/webp',
      };

  static Future<Uint8List> _readHeader(File file) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in file.openRead(
        0,
        ReverseImageInputLimits.maxHeaderBytes,
      )) {
        builder.add(chunk);
        if (builder.length >= ReverseImageInputLimits.maxHeaderBytes) break;
      }
    } on FileSystemException {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'selected image could not be read',
      );
    }
    return builder.takeBytes();
  }
}

class _ImageHeader {
  const _ImageHeader(this.format, this.width, this.height);

  final ReverseImageFormat format;
  final int width;
  final int height;
}

abstract final class _ImageHeaderParser {
  static _ImageHeader parse(Uint8List bytes) {
    if (_hasPrefix(bytes, const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ])) {
      return _parsePng(bytes);
    }
    if (_hasPrefix(bytes, const [0xff, 0xd8])) return _parseJpeg(bytes);
    if (_asciiAt(bytes, 0, 'GIF87a') || _asciiAt(bytes, 0, 'GIF89a')) {
      return _parseGif(bytes);
    }
    if (_asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'WEBP')) {
      return _parseWebp(bytes);
    }
    throw const ReverseImageInputException(
      ReverseImageInputFailureCode.unsupportedFormat,
      'image format is not supported',
    );
  }

  static _ImageHeader _parsePng(Uint8List bytes) {
    if (bytes.length < 24 ||
        _be32(bytes, 8) != 13 ||
        !_asciiAt(bytes, 12, 'IHDR')) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.malformedFormat,
        'PNG header is malformed',
      );
    }
    final width = _be32(bytes, 16);
    final height = _be32(bytes, 20);
    if (width <= 0 || height <= 0) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.malformedFormat,
        'PNG dimensions are invalid',
      );
    }
    return _ImageHeader(ReverseImageFormat.png, width, height);
  }

  static _ImageHeader _parseGif(Uint8List bytes) {
    if (bytes.length < 10) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.malformedFormat,
        'GIF header is malformed',
      );
    }
    final width = _le16(bytes, 6);
    final height = _le16(bytes, 8);
    if (width <= 0 || height <= 0) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.malformedFormat,
        'GIF dimensions are invalid',
      );
    }
    return _ImageHeader(ReverseImageFormat.gif, width, height);
  }

  static _ImageHeader _parseJpeg(Uint8List bytes) {
    var offset = 2;
    const frameMarkers = <int>{
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    };
    while (offset + 3 < bytes.length) {
      if (bytes[offset] != 0xff) {
        throw const ReverseImageInputException(
          ReverseImageInputFailureCode.malformedFormat,
          'JPEG marker is malformed',
        );
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd9 || marker == 0xda) break;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) break;
      final length = _be16(bytes, offset);
      if (length < 2 || offset + length > bytes.length) break;
      if (frameMarkers.contains(marker)) {
        if (length < 7) break;
        final height = _be16(bytes, offset + 3);
        final width = _be16(bytes, offset + 5);
        if (width <= 0 || height <= 0) break;
        return _ImageHeader(ReverseImageFormat.jpeg, width, height);
      }
      offset += length;
    }
    throw const ReverseImageInputException(
      ReverseImageInputFailureCode.malformedFormat,
      'JPEG dimensions are missing',
    );
  }

  static _ImageHeader _parseWebp(Uint8List bytes) {
    if (bytes.length < 30) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.malformedFormat,
        'WebP header is malformed',
      );
    }
    if (_asciiAt(bytes, 12, 'VP8X')) {
      final width = 1 + _le24(bytes, 24);
      final height = 1 + _le24(bytes, 27);
      return _ImageHeader(ReverseImageFormat.webp, width, height);
    }
    if (_asciiAt(bytes, 12, 'VP8 ')) {
      if (bytes.length < 34 ||
          bytes[26] != 0x9d ||
          bytes[27] != 0x01 ||
          bytes[28] != 0x2a) {
        throw const ReverseImageInputException(
          ReverseImageInputFailureCode.malformedFormat,
          'lossy WebP header is malformed',
        );
      }
      final width = _le16(bytes, 30) & 0x3fff;
      final height = _le16(bytes, 32) & 0x3fff;
      if (width <= 0 || height <= 0) {
        throw const ReverseImageInputException(
          ReverseImageInputFailureCode.malformedFormat,
          'WebP dimensions are invalid',
        );
      }
      return _ImageHeader(ReverseImageFormat.webp, width, height);
    }
    if (_asciiAt(bytes, 12, 'VP8L')) {
      if (bytes.length < 25 || bytes[20] != 0x2f) {
        throw const ReverseImageInputException(
          ReverseImageInputFailureCode.malformedFormat,
          'lossless WebP header is malformed',
        );
      }
      final width = 1 + ((bytes[21] | (bytes[22] << 8)) & 0x3fff);
      final height =
          1 +
          (((bytes[22] >> 6) | (bytes[23] << 2) | (bytes[24] << 10)) & 0x3fff);
      return _ImageHeader(ReverseImageFormat.webp, width, height);
    }
    throw const ReverseImageInputException(
      ReverseImageInputFailureCode.unsupportedFormat,
      'WebP variant is not supported',
    );
  }

  static bool _hasPrefix(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  static bool _asciiAt(List<int> bytes, int offset, String value) {
    if (offset < 0 || offset + value.length > bytes.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (bytes[offset + index] != value.codeUnitAt(index)) return false;
    }
    return true;
  }

  static int _be16(List<int> bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];

  static int _be32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _le16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _le24(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}
