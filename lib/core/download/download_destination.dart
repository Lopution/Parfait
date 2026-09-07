import 'package:meta/meta.dart';

/// Where a finished download lands (D5).
///
/// This is the single contract shared by settings (persisted selection),
/// download request normalization and recovery owner definition (C4/C5/C22).
/// There is intentionally no free-text path: a destination is either the
/// built-in PixivFunc album, a user-named MediaStore album, or a SAF tree
/// URI granted through the system directory picker.
@immutable
class DownloadDestination {
  const DownloadDestination.pixivAlbum()
    : kind = DownloadDestinationKind.pixivAlbum,
      customAlbumName = null,
      safTreeUri = null;

  const DownloadDestination.customAlbum(String name)
    : kind = DownloadDestinationKind.customAlbum,
      customAlbumName = name,
      safTreeUri = null;

  const DownloadDestination.safFolder(String treeUri)
    : kind = DownloadDestinationKind.safFolder,
      customAlbumName = null,
      safTreeUri = treeUri;

  final DownloadDestinationKind kind;
  final String? customAlbumName;
  final String? safTreeUri;

  static const DownloadDestination builtin = DownloadDestination.pixivAlbum();

  bool get isBuiltin => kind == DownloadDestinationKind.pixivAlbum;
  bool get isSafFolder => kind == DownloadDestinationKind.safFolder;

  /// Stable identity used by recovery records. Never contains a tree URI
  /// permission lease; only the opaque, canonical selection.
  String get identity => switch (kind) {
    DownloadDestinationKind.pixivAlbum => 'album:pixivfunc',
    DownloadDestinationKind.customAlbum =>
      'album:${customAlbumName ?? 'unnamed'}',
    DownloadDestinationKind.safFolder => 'saf:${safTreeUri ?? ''}',
  };

  /// Canonical safe album name for [customAlbumName]: trims separators and
  /// accepts at most one non-empty path segment for display purposes.
  static String? normalizeAlbumName(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.contains('..')) {
      return null;
    }
    if (trimmed == '.' ||
        trimmed == '..' ||
        trimmed.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return null;
    }
    return trimmed.length <= 64 ? trimmed : trimmed.substring(0, 64);
  }

  Map<String, dynamic> toJson() => switch (kind) {
    DownloadDestinationKind.pixivAlbum => const {
      'destinationKind': 'pixivAlbum',
    },
    DownloadDestinationKind.customAlbum => {
      'destinationKind': 'customAlbum',
      'customAlbumName': customAlbumName,
    },
    DownloadDestinationKind.safFolder => {
      'destinationKind': 'safFolder',
      'safTreeUri': safTreeUri,
    },
  };

  static DownloadDestination fromJson(
    Map<String, dynamic> json, {
    DownloadDestination fallback = builtin,
  }) {
    final kind = json['destinationKind'];
    if (kind == 'customAlbum') {
      final name = normalizeAlbumName(
        json['customAlbumName'] is String
            ? json['customAlbumName'] as String
            : null,
      );
      if (name != null) return DownloadDestination.customAlbum(name);
      return fallback;
    }
    if (kind == 'safFolder') {
      final uri = json['safTreeUri'];
      if (uri is String && uri.isNotEmpty && uri.length <= 4096) {
        return DownloadDestination.safFolder(uri);
      }
      return fallback;
    }
    if (kind == 'pixivAlbum') return builtin;
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadDestination &&
      other.kind == kind &&
      other.customAlbumName == customAlbumName &&
      other.safTreeUri == safTreeUri;

  @override
  int get hashCode => Object.hash(kind, customAlbumName, safTreeUri);

  @override
  String toString() => 'DownloadDestination($kind)';
}

enum DownloadDestinationKind { pixivAlbum, customAlbum, safFolder }
