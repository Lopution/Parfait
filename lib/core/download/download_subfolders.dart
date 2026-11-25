import '../settings/settings_enums.dart';
import 'download_destination.dart';

/// Maximum characters per sanitized subdirectory segment so nested MediaStore
/// paths stay well under Android's 128-character `RELATIVE_PATH` cap.
const int kMaxSubdirectorySegmentLength = 64;

/// Android `MediaStoreChannel` enforces `relativePath.length <= 128`.
const int kMaxMediaStoreRelativePathLength = 128;

const Set<String> _windowsReservedSegmentNames = {
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

final _unsafeSegmentChars = RegExp(r'[<>:"/\\|?*\x00-\x1F\x7F]');
final _trailingDotsOrSpaces = RegExp(r'[. ]+$');

/// Sanitizes a single relative directory segment so it is safe across Android
/// MediaStore, Android SAF, Windows, macOS, and Linux filesystems.
String sanitizeSubdirectorySegment(String raw, {String fallback = 'work'}) {
  var cleaned = raw.replaceAll(_unsafeSegmentChars, '_').trim();
  while (cleaned.contains('__')) {
    cleaned = cleaned.replaceAll('__', '_');
  }
  cleaned = cleaned.replaceAll(_trailingDotsOrSpaces, '');
  while (cleaned.startsWith('.')) {
    cleaned = cleaned.substring(1).trimLeft();
  }
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return fallback;
  }
  if (cleaned.length > kMaxSubdirectorySegmentLength) {
    cleaned = cleaned
        .substring(0, kMaxSubdirectorySegmentLength)
        .replaceAll(_trailingDotsOrSpaces, '');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return fallback;
    }
  }
  final dotIndex = cleaned.indexOf('.');
  final stem = (dotIndex == -1 ? cleaned : cleaned.substring(0, dotIndex))
      .toUpperCase();
  if (_windowsReservedSegmentNames.contains(stem)) {
    cleaned = '_$cleaned';
  }
  return cleaned;
}

/// Validates a single relative subdirectory segment (used on recovery records
/// and channel inputs to reject traversal or platform-illegal names).
void validateSubdirectorySegment(String segment) {
  if (segment.isEmpty || segment.length > 128) {
    throw FormatException('invalid subdirectory length: $segment');
  }
  if (segment == '.' ||
      segment == '..' ||
      segment.startsWith('.') ||
      segment.endsWith('.') ||
      segment.endsWith(' ')) {
    throw FormatException('unsafe subdirectory segment: $segment');
  }
  if (segment.contains('/') ||
      segment.contains('\\') ||
      segment.contains('..')) {
    throw FormatException('path separator in subdirectory segment: $segment');
  }
  for (final unit in segment.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) {
      throw FormatException('control character in subdirectory segment');
    }
  }
  final dotIndex = segment.indexOf('.');
  final stem = (dotIndex == -1 ? segment : segment.substring(0, dotIndex))
      .toUpperCase();
  if (_windowsReservedSegmentNames.contains(stem)) {
    throw FormatException('reserved subdirectory name: $segment');
  }
}

/// Validates every segment in [subdirectories].
void validateSubdirectories(List<String> subdirectories) {
  for (final segment in subdirectories) {
    validateSubdirectorySegment(segment);
  }
}

/// Resolves validated relative subdirectories for a work download based on the
/// selected [mode] and [multiPageSubfolder] setting.
List<String> resolveWorkSubdirectories({
  required DownloadSubfolderMode mode,
  required bool multiPageSubfolder,
  required int illustId,
  required int pageCount,
  String? artist,
  int? authorId,
  String? seriesTitle,
  int? seriesId,
}) {
  final segments = <String>[];
  if (mode == DownloadSubfolderMode.byArtist ||
      mode == DownloadSubfolderMode.byArtistAndSeries) {
    final fallbackArtist = authorId != null && authorId > 0
        ? 'artist_$authorId'
        : 'artist';
    segments.add(
      sanitizeSubdirectorySegment(
        artist ?? fallbackArtist,
        fallback: fallbackArtist,
      ),
    );
  }
  if (mode == DownloadSubfolderMode.byArtistAndSeries &&
      seriesTitle != null &&
      seriesTitle.trim().isNotEmpty) {
    final fallbackSeries = seriesId != null && seriesId > 0
        ? 'series_$seriesId'
        : 'series';
    segments.add(
      sanitizeSubdirectorySegment(seriesTitle, fallback: fallbackSeries),
    );
  }
  if (multiPageSubfolder && pageCount > 1) {
    segments.add(
      sanitizeSubdirectorySegment('$illustId', fallback: '$illustId'),
    );
  }
  return List<String>.unmodifiable(segments);
}

/// Builds the Android MediaStore / Desktop `RELATIVE_PATH` (`Pictures/<album>`
/// plus optional sanitized [subdirectories]), clamped to Android's 128-char
/// limit (`MediaStoreChannel.beginPending`).
String? mediaStoreRelativePathFor(
  DownloadDestination destination, {
  List<String> subdirectories = const [],
}) {
  if (destination.kind == DownloadDestinationKind.safFolder) return null;
  if (subdirectories.isEmpty) {
    return switch (destination.kind) {
      DownloadDestinationKind.pixivAlbum => null,
      DownloadDestinationKind.customAlbum =>
        'Pictures/${destination.customAlbumName ?? 'Parfait'}',
      DownloadDestinationKind.safFolder => null,
    };
  }
  final base = destination.kind == DownloadDestinationKind.customAlbum
      ? 'Pictures/${destination.customAlbumName ?? 'Parfait'}'
      : 'Pictures/Parfait';
  final buffer = StringBuffer(base);
  for (final raw in subdirectories) {
    final segment = sanitizeSubdirectorySegment(raw);
    final remaining = kMaxMediaStoreRelativePathLength - buffer.length - 1;
    if (remaining <= 0) break;
    var fitted = segment.length <= remaining
        ? segment
        : segment.substring(0, remaining).replaceAll(_trailingDotsOrSpaces, '');
    if (fitted.isEmpty || fitted == '.' || fitted == '..') continue;
    final dotIndex = fitted.indexOf('.');
    final stem = (dotIndex == -1 ? fitted : fitted.substring(0, dotIndex))
        .toUpperCase();
    if (_windowsReservedSegmentNames.contains(stem)) {
      if (fitted.length + 1 <= remaining) {
        fitted = '_$fitted';
      } else {
        continue;
      }
    }
    buffer
      ..write('/')
      ..write(fitted);
  }
  return buffer.toString();
}
