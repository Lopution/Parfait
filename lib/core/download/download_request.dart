import 'package:meta/meta.dart';

import '../network/compat/network_contracts.dart';

/// What a download produces. `illustPage` names files by page index inside
/// the detail flow; `ugoiraZip` is reserved for the later ugoira export task.
/// `updaterApk` is an app-private signed-release download.
enum DownloadTarget { illustPage, ugoiraZip, ugoiraGif, updaterApk }

/// Typed download request submitted by feature code (detail page, ugoira
/// export). Carries everything normalization needs; consumers never touch
/// transport internals.
@immutable
class DownloadRequest {
  const DownloadRequest({
    required this.illustId,
    required this.pageIndex,
    required this.url,
    required this.target,
  }) : assert(illustId > 0),
       assert(pageIndex >= 0);

  final int illustId;
  final int pageIndex;
  final Uri url;
  final DownloadTarget target;

  /// Dedupe identity: illust + page + normalized URL + target (R4).
  String get dedupeKey =>
      '$target|$illustId|$pageIndex|${_normalizeUrl(url, target)}';

  /// Extension derived from the URL; empty string when absent.
  String get extension {
    final path = url.path;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  /// Traversal-safe display name: `<illustId>_p<index>.<ext>`.
  /// Throws [FormatException] for URLs without a usable image extension.
  String get displayName {
    final ext = _safeExtension(extension);
    return '$illustId'
        '_p$pageIndex.$ext';
  }

  String get mimeType => mimeTypeForExtension(extension);
}

/// Extensions a download may write; anything else is rejected before queueing.
const Set<String> kDownloadExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'zip',
  'apk',
};

String mimeTypeForExtension(String extension) {
  switch (extension) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'zip':
      return 'application/zip';
    case 'apk':
      return 'application/vnd.android.package-archive';
    default:
      throw FormatException('unsupported download extension: $extension');
  }
}

String _safeExtension(String raw) {
  if (!kDownloadExtensions.contains(raw)) {
    throw FormatException('unsupported download extension: $raw');
  }
  return raw == 'jpeg' ? 'jpg' : raw;
}

/// Strips query/fragment and lowercases host so the same logical asset maps
/// to one dedupe key. (Uri.replace(query: null) keeps the query, so the
/// clean URI is rebuilt explicitly.)
String _normalizeUrl(Uri url, DownloadTarget target) {
  if (target == DownloadTarget.updaterApk) return url.toString();
  return Uri(
    scheme: url.scheme,
    host: url.host.toLowerCase(),
    path: url.path,
  ).toString();
}

/// Validates a display name for filesystem/MediaStore safety (R4):
/// traversal segments, separators and control characters are rejected.
void validateDisplayName(String name) {
  if (name.isEmpty || name.length > 255) {
    throw FormatException('invalid display name length');
  }
  if (name == '.' || name == '..') {
    throw FormatException('invalid display name segment');
  }
  for (final char in name.codeUnits) {
    if (char < 0x20 || char == 0x7f) {
      throw FormatException('control character in display name');
    }
  }
  if (name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.startsWith('.')) {
    throw FormatException('unsafe display name: $name');
  }
}

/// Throws when the URL is not an allowed download host (R7).
void validateDownloadUrl(
  Uri url, {
  DownloadTarget target = DownloadTarget.illustPage,
}) {
  if (target == DownloadTarget.updaterApk) {
    if (!isStrictUpdateAssetUrl(url)) {
      throw const FormatException('update asset URL rejected');
    }
    return;
  }
  try {
    PixivDestinationRegistry().require(url, PixivDestinationPurpose.image);
  } on PixivDestinationException catch (error) {
    throw FormatException('download URL rejected: $error');
  }
}

/// Exact HTTPS hosts allowed for a signed updater asset. This set is separate
/// from the Pixiv image destination policy.
const Set<String> kUpdateDownloadHosts = <String>{
  'github.com',
  'objects.githubusercontent.com',
  'github-releases.githubusercontent.com',
};

bool isStrictUpdateAssetUrl(Uri url) {
  return url.scheme == 'https' &&
      kUpdateDownloadHosts.contains(url.host.toLowerCase()) &&
      url.host.isNotEmpty &&
      url.userInfo.isEmpty &&
      !url.hasFragment &&
      (!url.hasPort || url.port == 443) &&
      !url.host.endsWith('.') &&
      !url.host.codeUnits.any((value) => value > 0x7f) &&
      url.path.toLowerCase().endsWith('.apk');
}
