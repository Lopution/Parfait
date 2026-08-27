import 'package:meta/meta.dart';

/// Typed resource caps for Ugoira archives, frames and decode windows
/// (PRD R2/R3: every cap is enforced BEFORE pixel or buffer allocation).
///
/// These are internal safety rails only — they never alter visible frame
/// timing or beta56 playback behavior. The defaults are generous for real
/// Pixiv ugoira works while rejecting zip-bomb / forged-header inputs.
@immutable
class UgoiraLimits {
  const UgoiraLimits({
    this.maxArchiveCompressedBytes = 64 * 1024 * 1024,
    this.maxArchiveUncompressedBytes = 256 * 1024 * 1024,
    this.maxEntryCount = 1024,
    this.maxFrameCount = 2048,
    this.maxCentralDirectoryBytes = 8 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.maxFrameUncompressedBytes = 48 * 1024 * 1024,
    this.maxFrameDimension = 16384,
    this.maxFramePixels = 16 * 1024 * 1024,
    this.maxDecodedWindowBytes = 96 * 1024 * 1024,
    this.maxExportBytes = 128 * 1024 * 1024,
  }) : assert(maxArchiveCompressedBytes > 0),
       assert(maxArchiveUncompressedBytes > maxArchiveCompressedBytes),
       assert(maxEntryCount > 0),
       assert(maxFrameCount > 0),
       assert(maxCentralDirectoryBytes > 0),
       assert(maxCompressionRatio > 1),
       assert(maxFrameUncompressedBytes > 0),
       assert(maxFrameDimension > 0),
       assert(maxFramePixels > 0),
       assert(maxDecodedWindowBytes > 0),
       assert(maxExportBytes > 0);

  /// Largest accepted ZIP file size on disk (owned temp file).
  final int maxArchiveCompressedBytes;

  /// Sum of declared uncompressed entry sizes across the archive.
  final int maxArchiveUncompressedBytes;

  /// Maximum number of entries in the ZIP.
  final int maxEntryCount;

  /// Maximum number of metadata-referenced animation frames.
  final int maxFrameCount;

  /// Maximum central-directory allocation while indexing an archive.
  final int maxCentralDirectoryBytes;

  /// Uncompressed/compressed ratio an archive may reach before it is treated
  /// as a compression bomb and rejected before any decompression work.
  final double maxCompressionRatio;

  /// Maximum uncompressed size of a single entry (one encoded frame image).
  final int maxFrameUncompressedBytes;

  /// Maximum width or height of a single decoded frame.
  final int maxFrameDimension;

  /// Maximum number of decoded pixels in one frame, checked from the image
  /// header before Flutter allocates a codec buffer.
  final int maxFramePixels;

  /// Combined byte budget of the decoded-frame LRU window
  /// (`width * height * 4` per resident `ui.Image`).
  final int maxDecodedWindowBytes;

  /// Maximum encoded GIF output retained before it is written to the sink.
  final int maxExportBytes;
}

const Duration kMaxUgoiraFrameDelayMs = Duration(milliseconds: 60000);
