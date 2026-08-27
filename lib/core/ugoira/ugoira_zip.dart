import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Inflate, getCrc32;

import 'ugoira_limits.dart';
import 'ugoira_metadata.dart';

/// Strict ZIP/index failure. It is intentionally separate from image decode
/// failures so the UI can report archive corruption and unsupported frames
/// distinctly.
class UgoiraArchiveException implements Exception {
  const UgoiraArchiveException(this.message);

  final String message;

  @override
  String toString() => 'UgoiraArchiveException: $message';
}

/// A central-directory entry whose local header and data range were checked.
class UgoiraZipEntry {
  const UgoiraZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.flags,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.dataOffset,
  });

  final String name;
  final int compressionMethod;
  final int flags;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final int dataOffset;
}

enum UgoiraImageFormat { jpeg, png, webp }

/// Image dimensions found from a bounded format header, before a Flutter
/// codec is created and before native pixel memory can be allocated.
class UgoiraFrameHeader {
  const UgoiraFrameHeader({
    required this.format,
    required this.width,
    required this.height,
  });

  final UgoiraImageFormat format;
  final int width;
  final int height;

  int get pixelCount => width * height;

  void validate(UgoiraLimits limits) {
    if (width <= 0 ||
        height <= 0 ||
        width > limits.maxFrameDimension ||
        height > limits.maxFrameDimension ||
        pixelCount > limits.maxFramePixels ||
        pixelCount > limits.maxDecodedWindowBytes ~/ 4) {
      throw const UgoiraArchiveException('frame dimensions exceed limit');
    }
  }

  static UgoiraFrameHeader parse(List<int> bytes) {
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
      if (bytes.length < 24 ||
          !_asciiAt(bytes, 12, 'IHDR') ||
          _be32(bytes, 16) == 0 ||
          _be32(bytes, 20) == 0) {
        throw const UgoiraArchiveException('PNG header is malformed');
      }
      return UgoiraFrameHeader(
        format: UgoiraImageFormat.png,
        width: _be32(bytes, 16),
        height: _be32(bytes, 20),
      );
    }

    if (_hasPrefix(bytes, const [0xff, 0xd8])) {
      return _parseJpeg(bytes);
    }

    if (_hasPrefix(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
        bytes.length >= 16 &&
        _asciiAt(bytes, 8, 'WEBP')) {
      return _parseWebp(bytes);
    }

    throw const UgoiraArchiveException('unsupported frame image format');
  }

  static UgoiraFrameHeader _parseJpeg(List<int> bytes) {
    var offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset] != 0xff) {
        throw const UgoiraArchiveException('JPEG marker is malformed');
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd9 || marker == 0xda) break;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (offset + 2 > bytes.length) break;
      final length = _be16(bytes, offset);
      if (length < 2 || offset + length > bytes.length) break;
      if (_isJpegStartOfFrame(marker)) {
        if (length < 7) break;
        final height = _be16(bytes, offset + 3);
        final width = _be16(bytes, offset + 5);
        if (width == 0 || height == 0) break;
        return UgoiraFrameHeader(
          format: UgoiraImageFormat.jpeg,
          width: width,
          height: height,
        );
      }
      offset += length;
    }
    throw const UgoiraArchiveException('JPEG dimensions are missing');
  }

  static UgoiraFrameHeader _parseWebp(List<int> bytes) {
    if (bytes.length < 30 || !_asciiAt(bytes, 12, 'VP8X')) {
      throw const UgoiraArchiveException(
        'WebP frame must expose a VP8X dimension header',
      );
    }
    final width = 1 + _le24(bytes, 24);
    final height = 1 + _le24(bytes, 27);
    return UgoiraFrameHeader(
      format: UgoiraImageFormat.webp,
      width: width,
      height: height,
    );
  }

  static bool _isJpegStartOfFrame(int marker) {
    return (marker >= 0xc0 && marker <= 0xc3) ||
        (marker >= 0xc5 && marker <= 0xc7) ||
        (marker >= 0xc9 && marker <= 0xcb) ||
        (marker >= 0xcd && marker <= 0xcf);
  }

  static bool _hasPrefix(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _asciiAt(List<int> bytes, int offset, String value) {
    if (offset + value.length > bytes.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value.codeUnitAt(i)) return false;
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

  static int _le24(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

/// A safe, random-access index over a disk-backed Ugoira ZIP.
class SafeZipIndex {
  SafeZipIndex._({
    required _ArchiveReader reader,
    required this.metadata,
    required this.limits,
    required List<UgoiraZipEntry> entries,
  }) : _reader = reader,
       entries = List.unmodifiable(entries);

  final _ArchiveReader _reader;
  final UgoiraMetadata metadata;
  final UgoiraLimits limits;
  final List<UgoiraZipEntry> entries;
  bool _closed = false;

  /// Test/debug constructor. Production uses [open] so the archive never
  /// needs to be retained as one in-memory byte array.
  static SafeZipIndex fromBytes(
    List<int> bytes, {
    required UgoiraMetadata metadata,
    UgoiraLimits limits = const UgoiraLimits(),
  }) {
    final data = Uint8List.fromList(bytes);
    if (data.length > limits.maxArchiveCompressedBytes) {
      throw const UgoiraArchiveException('archive exceeds compressed limit');
    }
    final eocd = _readEocd(data, data.length, baseOffset: 0);
    if (eocd.centralSize > limits.maxCentralDirectoryBytes) {
      throw const UgoiraArchiveException('central directory exceeds limit');
    }
    final central = data.sublist(eocd.centralOffset, eocd.centralEnd);
    final drafts = _parseCentral(
      central,
      archiveLength: data.length,
      eocd: eocd,
      metadata: metadata,
      limits: limits,
    );
    final entries = [
      for (final draft in drafts)
        _completeEntryFromBytes(
          draft,
          data,
          archiveLength: data.length,
          centralOffset: eocd.centralOffset,
        ),
    ];
    _validateEntryLayout(entries, eocd.centralOffset);
    return SafeZipIndex._(
      reader: _MemoryArchiveReader(data),
      metadata: metadata,
      limits: limits,
      entries: _orderEntries(entries, metadata),
    );
  }

  /// Opens and validates only ZIP metadata/local headers. Entry bodies are
  /// read and inflated one frame at a time by [readFrameBytes].
  static Future<SafeZipIndex> open(
    File file, {
    required UgoiraMetadata metadata,
    UgoiraLimits limits = const UgoiraLimits(),
  }) async {
    final raf = await file.open();
    final reader = _FileArchiveReader(raf);
    try {
      final length = await raf.length();
      if (length > limits.maxArchiveCompressedBytes) {
        throw const UgoiraArchiveException('archive exceeds compressed limit');
      }
      final tailLength = length < 65557 ? length : 65557;
      final tail = await reader.read(length - tailLength, tailLength);
      final eocd = _readEocd(tail, length, baseOffset: length - tailLength);
      if (eocd.centralSize > limits.maxCentralDirectoryBytes) {
        throw const UgoiraArchiveException('central directory exceeds limit');
      }
      final central = await reader.read(eocd.centralOffset, eocd.centralSize);
      final drafts = _parseCentral(
        central,
        archiveLength: length,
        eocd: eocd,
        metadata: metadata,
        limits: limits,
      );
      final entries = <UgoiraZipEntry>[];
      for (final draft in drafts) {
        final localPrefix = await reader.read(draft.localHeaderOffset, 30);
        final localLength = _localHeaderLength(localPrefix);
        final local = await reader.read(draft.localHeaderOffset, localLength);
        entries.add(
          _completeEntry(
            draft,
            local,
            archiveLength: length,
            centralOffset: eocd.centralOffset,
          ),
        );
      }
      _validateEntryLayout(entries, eocd.centralOffset);
      return SafeZipIndex._(
        reader: reader,
        metadata: metadata,
        limits: limits,
        entries: _orderEntries(entries, metadata),
      );
    } catch (_) {
      await reader.close();
      rethrow;
    }
  }

  Future<List<int>> readFrameBytes(int index) async {
    _ensureOpen();
    if (index < 0 || index >= entries.length) {
      throw RangeError.index(index, entries, 'index');
    }
    return _readEntry(entries[index]);
  }

  Future<UgoiraFrameHeader> inspectFrame(int index) async {
    final bytes = await readFrameBytes(index);
    final header = UgoiraFrameHeader.parse(bytes);
    _validateFrameHeader(header);
    return header;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _reader.close();
  }

  Future<List<int>> _readEntry(UgoiraZipEntry entry) async {
    final compressed = await _reader.read(
      entry.dataOffset,
      entry.compressedSize,
    );
    List<int> decoded;
    try {
      decoded = switch (entry.compressionMethod) {
        0 => compressed,
        8 => Inflate(compressed, entry.uncompressedSize).getBytes(),
        _ => throw const UgoiraArchiveException('compression method rejected'),
      };
    } catch (error) {
      if (error is UgoiraArchiveException) rethrow;
      throw UgoiraArchiveException('frame decompression failed: $error');
    }
    if (decoded.length != entry.uncompressedSize) {
      throw const UgoiraArchiveException('entry size does not match metadata');
    }
    if (getCrc32(decoded) != entry.crc32) {
      throw const UgoiraArchiveException('entry CRC mismatch');
    }
    return decoded;
  }

  void _validateFrameHeader(UgoiraFrameHeader header) {
    header.validate(limits);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('ugoira archive is disposed');
  }
}

List<UgoiraZipEntry> _orderEntries(
  List<UgoiraZipEntry> entries,
  UgoiraMetadata metadata,
) {
  final byName = <String, UgoiraZipEntry>{
    for (final entry in entries) entry.name: entry,
  };
  final ordered = <UgoiraZipEntry>[];
  for (final frame in metadata.frames) {
    final entry = byName[frame.file];
    if (entry == null) {
      throw const UgoiraArchiveException(
        'ZIP entry is missing a metadata frame',
      );
    }
    ordered.add(entry);
  }
  return ordered;
}

class _Eocd {
  const _Eocd({
    required this.offset,
    required this.centralOffset,
    required this.centralSize,
    required this.entryCount,
  });

  final int offset;
  final int centralOffset;
  final int centralSize;
  final int entryCount;

  int get centralEnd => centralOffset + centralSize;
}

class _EntryDraft {
  const _EntryDraft({
    required this.name,
    required this.compressionMethod,
    required this.flags,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  final String name;
  final int compressionMethod;
  final int flags;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
}

_Eocd _readEocd(Uint8List bytes, int archiveLength, {required int baseOffset}) {
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (_u32(bytes, i) != 0x06054b50) continue;
    final commentLength = _u16(bytes, i + 20);
    if (i + 22 + commentLength != bytes.length) continue;
    final disk = _u16(bytes, i + 4);
    final centralDisk = _u16(bytes, i + 6);
    final entriesOnDisk = _u16(bytes, i + 8);
    final entries = _u16(bytes, i + 10);
    final centralSize = _u32(bytes, i + 12);
    final centralOffset = _u32(bytes, i + 16);
    if (disk != 0 ||
        centralDisk != 0 ||
        entriesOnDisk != entries ||
        entries == 0xffff ||
        centralSize == 0xffffffff ||
        centralOffset == 0xffffffff) {
      throw const UgoiraArchiveException(
        'ZIP64 or multi-disk archive rejected',
      );
    }
    final absoluteOffset = centralOffset;
    if (absoluteOffset < 0 ||
        centralSize > archiveLength - absoluteOffset ||
        absoluteOffset + centralSize > baseOffset + i) {
      throw const UgoiraArchiveException('central directory range is invalid');
    }
    return _Eocd(
      offset: baseOffset + i,
      centralOffset: absoluteOffset,
      centralSize: centralSize,
      entryCount: entries,
    );
  }
  throw const UgoiraArchiveException('ZIP end record is missing');
}

List<_EntryDraft> _parseCentral(
  Uint8List central, {
  required int archiveLength,
  required _Eocd eocd,
  required UgoiraMetadata metadata,
  required UgoiraLimits limits,
}) {
  if (central.length > limits.maxCentralDirectoryBytes) {
    throw const UgoiraArchiveException('central directory exceeds limit');
  }
  if (eocd.entryCount > limits.maxEntryCount ||
      eocd.entryCount > limits.maxFrameCount ||
      eocd.entryCount != metadata.frames.length) {
    throw const UgoiraArchiveException('ZIP entry count does not match frames');
  }
  final expected = metadata.frames.map((frame) => frame.file).toSet();
  final seen = <String>{};
  final drafts = <_EntryDraft>[];
  var offset = 0;
  var compressedTotal = 0;
  var uncompressedTotal = 0;
  for (var i = 0; i < eocd.entryCount; i++) {
    if (offset + 46 > central.length || _u32(central, offset) != 0x02014b50) {
      throw const UgoiraArchiveException(
        'central directory entry is malformed',
      );
    }
    final flags = _u16(central, offset + 8);
    final compression = _u16(central, offset + 10);
    final crc32 = _u32(central, offset + 16);
    final compressedSize = _u32(central, offset + 20);
    final uncompressedSize = _u32(central, offset + 24);
    final nameLength = _u16(central, offset + 28);
    final extraLength = _u16(central, offset + 30);
    final commentLength = _u16(central, offset + 32);
    final diskNumber = _u16(central, offset + 34);
    final localHeaderOffset = _u32(central, offset + 42);
    if (compressedSize == 0xffffffff ||
        uncompressedSize == 0xffffffff ||
        localHeaderOffset == 0xffffffff ||
        (flags & 0x1) != 0 ||
        diskNumber != 0 ||
        (compression != 0 && compression != 8) ||
        uncompressedSize > limits.maxFrameUncompressedBytes) {
      throw const UgoiraArchiveException(
        'ZIP entry uses an unsupported feature',
      );
    }
    final recordLength = 46 + nameLength + extraLength + commentLength;
    if (offset + recordLength > central.length ||
        localHeaderOffset > archiveLength - 30) {
      throw const UgoiraArchiveException('ZIP entry range is invalid');
    }
    final nameBytes = central.sublist(offset + 46, offset + 46 + nameLength);
    final name = _decodeName(nameBytes);
    if (!_isSafeName(name) || !expected.contains(name) || !seen.add(name)) {
      throw const UgoiraArchiveException(
        'ZIP entry name is not an expected frame',
      );
    }
    compressedTotal += compressedSize;
    uncompressedTotal += uncompressedSize;
    if (compressedTotal > limits.maxArchiveCompressedBytes ||
        uncompressedTotal > limits.maxArchiveUncompressedBytes) {
      throw const UgoiraArchiveException('archive size limit exceeded');
    }
    drafts.add(
      _EntryDraft(
        name: name,
        compressionMethod: compression,
        flags: flags,
        crc32: crc32,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
      ),
    );
    offset += recordLength;
  }
  if (offset != central.length || seen.length != expected.length) {
    throw const UgoiraArchiveException(
      'central directory has trailing or missing entries',
    );
  }
  if (compressedTotal == 0 && uncompressedTotal > 0 ||
      compressedTotal > 0 &&
          uncompressedTotal / compressedTotal > limits.maxCompressionRatio) {
    throw const UgoiraArchiveException(
      'archive compression ratio exceeds limit',
    );
  }
  return drafts;
}

UgoiraZipEntry _completeEntryFromBytes(
  _EntryDraft draft,
  Uint8List archive, {
  required int archiveLength,
  required int centralOffset,
}) {
  if (draft.localHeaderOffset < 0 ||
      draft.localHeaderOffset > archiveLength - 30) {
    throw const UgoiraArchiveException('local ZIP header range is invalid');
  }
  final prefix = archive.sublist(
    draft.localHeaderOffset,
    draft.localHeaderOffset + 30,
  );
  final length = _localHeaderLength(prefix);
  if (length > archiveLength - draft.localHeaderOffset) {
    throw const UgoiraArchiveException('local ZIP header is truncated');
  }
  final local = archive.sublist(
    draft.localHeaderOffset,
    draft.localHeaderOffset + length,
  );
  return _completeEntry(
    draft,
    local,
    archiveLength: archiveLength,
    centralOffset: centralOffset,
  );
}

int _localHeaderLength(Uint8List local) {
  if (local.length < 30 || _u32(local, 0) != 0x04034b50) {
    throw const UgoiraArchiveException('local ZIP header is malformed');
  }
  final nameLength = _u16(local, 26);
  final extraLength = _u16(local, 28);
  return 30 + nameLength + extraLength;
}

UgoiraZipEntry _completeEntry(
  _EntryDraft draft,
  Uint8List local, {
  required int archiveLength,
  required int centralOffset,
}) {
  if (local.length < 30 || _u32(local, 0) != 0x04034b50) {
    throw const UgoiraArchiveException('local ZIP header is malformed');
  }
  final localFlags = _u16(local, 6);
  final localCompression = _u16(local, 8);
  final localCrc = _u32(local, 14);
  final localCompressed = _u32(local, 18);
  final localUncompressed = _u32(local, 22);
  final nameLength = _u16(local, 26);
  final extraLength = _u16(local, 28);
  final requiredLength = 30 + nameLength + extraLength;
  if (requiredLength > local.length) {
    throw const UgoiraArchiveException('local ZIP header is truncated');
  }
  final localName = _decodeName(local.sublist(30, 30 + nameLength));
  if (localName != draft.name ||
      localFlags != draft.flags ||
      localCompression != draft.compressionMethod ||
      (draft.flags & 0x8) == 0 &&
          (localCrc != draft.crc32 ||
              localCompressed != draft.compressedSize ||
              localUncompressed != draft.uncompressedSize)) {
    throw const UgoiraArchiveException('local and central ZIP headers differ');
  }
  final dataOffset = draft.localHeaderOffset + requiredLength;
  if (dataOffset < 0 ||
      dataOffset > archiveLength - draft.compressedSize ||
      dataOffset + draft.compressedSize > centralOffset) {
    throw const UgoiraArchiveException('ZIP entry data range is invalid');
  }
  return UgoiraZipEntry(
    name: draft.name,
    compressionMethod: draft.compressionMethod,
    flags: draft.flags,
    crc32: draft.crc32,
    compressedSize: draft.compressedSize,
    uncompressedSize: draft.uncompressedSize,
    localHeaderOffset: draft.localHeaderOffset,
    dataOffset: dataOffset,
  );
}

void _validateEntryLayout(List<UgoiraZipEntry> entries, int centralOffset) {
  final ranges = [
    for (final entry in entries)
      (
        start: entry.localHeaderOffset,
        end: entry.dataOffset + entry.compressedSize,
      ),
  ]..sort((left, right) => left.start.compareTo(right.start));
  var previousEnd = 0;
  for (final range in ranges) {
    if (range.start < 0 ||
        range.end < range.start ||
        range.end > centralOffset ||
        range.start < previousEnd) {
      throw const UgoiraArchiveException('ZIP entries overlap');
    }
    previousEnd = range.end;
  }
}

String _decodeName(List<int> bytes) {
  try {
    // Pixiv frame names are UTF-8/ASCII. Rejecting non-UTF-8 is safer than
    // guessing a legacy code page and accidentally changing path identity.
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const UgoiraArchiveException('ZIP entry name is not valid UTF-8');
  }
}

bool _isSafeName(String name) {
  if (name.isEmpty ||
      name.length > 255 ||
      name.startsWith('/') ||
      name.startsWith('\\') ||
      name.contains('/') ||
      name.contains('\\') ||
      name == '.' ||
      name == '..' ||
      name.contains('..')) {
    return false;
  }
  return !name.codeUnits.any(
    (unit) => unit == 0 || unit < 0x20 || unit == 0x7f,
  );
}

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

abstract class _ArchiveReader {
  Future<Uint8List> read(int offset, int length);

  Future<void> close();
}

class _MemoryArchiveReader implements _ArchiveReader {
  _MemoryArchiveReader(this._bytes);

  final Uint8List _bytes;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset > _bytes.length - length) {
      throw const UgoiraArchiveException('archive read range is invalid');
    }
    return Uint8List.sublistView(_bytes, offset, offset + length);
  }

  @override
  Future<void> close() async {}
}

class _FileArchiveReader implements _ArchiveReader {
  _FileArchiveReader(this._file);

  final RandomAccessFile _file;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0) {
      throw const UgoiraArchiveException('archive read range is invalid');
    }
    try {
      await _file.setPosition(offset);
      final bytes = await _file.read(length);
      if (bytes.length != length) {
        throw const UgoiraArchiveException('archive read was truncated');
      }
      return Uint8List.fromList(bytes);
    } on UgoiraArchiveException {
      rethrow;
    } on FileSystemException catch (error) {
      throw UgoiraArchiveException('archive read failed: $error');
    }
  }

  @override
  Future<void> close() => _file.close();
}
