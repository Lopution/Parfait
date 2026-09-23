import '../../l10n/app_localizations.dart';

final _sdCardVolume = RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$');

/// Best-effort human label for a persisted SAF tree identifier (R6).
///
/// Android `content://…/tree/<docId>` URIs encode `<volume>:<path>` in the
/// segment after `tree`: `primary` is internal storage and a `XXXX-XXXX`
/// volume id is an SD card. Desktop pickers return plain filesystem paths,
/// which pass through verbatim. Anything unparseable falls back to the
/// decoded tail — a wrong label is worse than an honest one.
String safTreeDisplayName(AppLocalizations l10n, String treeUri) {
  final coordinates = parseSafTreeUri(treeUri);
  if (coordinates == null) return treeUri;
  final volume = coordinates.volume;
  final path = coordinates.path;
  final volumeLabel = switch (volume) {
    'primary' => l10n.safStorageInternal,
    _ when _sdCardVolume.hasMatch(volume) => l10n.safStorageSdCard(volume),
    _ => volume,
  };
  if (volumeLabel.isEmpty) return path;
  return path.isEmpty ? volumeLabel : '$volumeLabel/$path';
}

/// Splits a `content://…/tree/<docId>` identifier into its `<volume>:<path>`
/// coordinates. Returns null when [treeUri] is not a content URI (desktop
/// paths) or carries no tree segment — callers then show the raw string.
({String volume, String path})? parseSafTreeUri(String treeUri) {
  final uri = Uri.tryParse(treeUri);
  if (uri == null || uri.scheme != 'content') return null;
  final segments = uri.pathSegments;
  final treeIndex = segments.indexOf('tree');
  if (treeIndex < 0 || treeIndex + 1 >= segments.length) return null;
  // `pathSegments` arrives percent-decoded, so `primary%3ADownload` is
  // already `primary:Download` here.
  final id = segments[treeIndex + 1];
  if (id.isEmpty) return null;
  final colon = id.indexOf(':');
  if (colon < 0) return (volume: '', path: id);
  return (volume: id.substring(0, colon), path: id.substring(colon + 1));
}
