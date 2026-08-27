import 'package:meta/meta.dart';

import '../download/download_request.dart';
import 'ugoira_limits.dart';

/// One ordered animation frame from `GET /v1/ugoira/metadata`.
@immutable
class UgoiraFrameMetadata {
  const UgoiraFrameMetadata({required this.file, required this.delayMs})
    : assert(delayMs > 0);

  /// Exact ZIP entry name referenced by the metadata.
  final String file;

  /// Frame duration in milliseconds; order defines playback order.
  final int delayMs;
}

/// Typed ugoira metadata. Strict parse (PRD R1): malformed envelopes, unsafe
/// URLs, empty/negative delays or missing ZIP urls fail loudly instead of
/// being defaulted.
@immutable
class UgoiraMetadata {
  const UgoiraMetadata._({required this.zipUrl, required this.frames});

  final Uri zipUrl;
  final List<UgoiraFrameMetadata> frames;

  int delayForIndex(int index) => frames[index].delayMs;

  factory UgoiraMetadata.fromJson(
    Map<String, dynamic> json, {
    UgoiraLimits limits = const UgoiraLimits(),
  }) {
    final inner = _stringMap(
      json['ugoira_metadata'],
      'ugoira metadata envelope is malformed',
    );

    final rawFrames = inner['frames'];
    if (rawFrames is! List ||
        rawFrames.isEmpty ||
        rawFrames.length > limits.maxFrameCount) {
      throw const FormatException('ugoira metadata has no frames');
    }
    final frames = <UgoiraFrameMetadata>[];
    final seenFiles = <String>{};
    for (final raw in rawFrames) {
      if (raw is! Map) {
        throw const FormatException('frame metadata is malformed');
      }
      final frame = _stringMap(raw, 'frame metadata is malformed');
      final file = frame['file'];
      final delay = frame['delay'];
      if (file is! String || !_isSafeFrameName(file) || !seenFiles.add(file)) {
        throw const FormatException('frame file name missing');
      }
      if (delay is! int ||
          delay <= 0 ||
          delay > kMaxUgoiraFrameDelayMs.inMilliseconds) {
        throw FormatException('frame delay out of range: $delay');
      }
      frames.add(UgoiraFrameMetadata(file: file, delayMs: delay));
    }

    final zipUrls = _stringMap(inner['zip_urls'], 'ugoira zip_urls missing');
    final medium = zipUrls['medium'];
    if (medium is! String || medium.isEmpty) {
      throw const FormatException('ugoira medium zip url missing');
    }
    final url = Uri.tryParse(medium);
    if (url == null) {
      throw const FormatException('ugoira zip url unparseable');
    }
    // Same host allowlist as every other download surface (strict TLS/R7).
    validateDownloadUrl(url);

    return UgoiraMetadata._(zipUrl: url, frames: List.unmodifiable(frames));
  }

  static bool _isSafeFrameName(String name) {
    if (name.isEmpty ||
        name.length > 255 ||
        name.startsWith('/') ||
        name.startsWith('\\') ||
        name.contains('/') ||
        name.contains('\\') ||
        name == '.' ||
        name == '..' ||
        name.contains('..') ||
        name.codeUnits.any(
          (unit) => unit == 0 || unit < 0x20 || unit == 0x7f,
        )) {
      return false;
    }
    return true;
  }

  static Map<String, dynamic> _stringMap(Object? value, String errorMessage) {
    if (value is! Map) throw FormatException(errorMessage);
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) throw FormatException(errorMessage);
      result[entry.key as String] = entry.value;
    }
    return result;
  }
}
