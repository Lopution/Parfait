import 'dart:convert';

import '../entity/json_read.dart';
import '../network/api_error.dart';

/// Parsed payload of the `/webview/v2/novel` page's embedded pixiv object.
///
/// The app-API `/v2/novel/detail` endpoint never returns a body: the novel
/// text only exists in this page's bootstrap script
/// (`Object.defineProperty(window, 'pixiv', {value: {…}})`). Every working
/// third-party client (PixEz, Shaft, pixes, skana_pix) sources text here.
class NovelWebPayload {
  const NovelWebPayload({
    required this.text,
    required this.images,
    required this.illustThumbs,
    this.seriesPrevId,
    this.seriesNextId,
  });

  /// Raw markup text (`[newpage]`, `[[rb:…]]`, `[pixivimage:…]` …).
  final String? text;

  /// `uploadedimage` identifier → resolved URL (prefers `original`).
  final Map<String, String> images;

  /// `pixivimage` identifier → preview URL resolved from the `illusts` map.
  final Map<String, String> illustThumbs;

  final int? seriesPrevId;
  final int? seriesNextId;
}

/// Extracts the embedded `pixiv.novel` object from a `/webview/v2/novel` page.
///
/// Fails loudly with [ApiParseError]: a silently tolerated shape change would
/// surface as an unexplained "content unavailable" instead of a diagnosis.
NovelWebPayload extractNovelWebPayload(String html) {
  const marker = "Object.defineProperty(window, 'pixiv'";
  final markerIndex = html.indexOf(marker);
  if (markerIndex < 0) {
    throw const ApiParseError(
      'webview novel page is missing the pixiv bootstrap script',
    );
  }
  const valueKey = 'value:';
  final valueIndex = html.indexOf(valueKey, markerIndex + marker.length);
  if (valueIndex < 0) {
    throw const ApiParseError('pixiv bootstrap script has no value entry');
  }
  final braceStart = html.indexOf('{', valueIndex + valueKey.length);
  if (braceStart < 0) {
    throw const ApiParseError('pixiv bootstrap value is not an object');
  }
  final object = _balancedObject(html, braceStart);
  final Map<String, dynamic> pixiv;
  try {
    pixiv = jsonDecode(_stripTrailingCommas(object)) as Map<String, dynamic>;
  } on FormatException catch (error) {
    throw ApiParseError(error);
  }
  final novel = pixiv['novel'];
  if (novel is! Map) {
    throw const ApiParseError('pixiv bootstrap object has no novel entry');
  }
  return _payload(readMap(novel));
}

/// Returns the `{…}` balanced-brace substring starting at [start].
String _balancedObject(String html, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    final unit = html.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5C) {
        escaped = true;
      } else if (unit == 0x22) {
        inString = false;
      }
      continue;
    }
    switch (unit) {
      case 0x22:
        inString = true;
      case 0x7B:
        depth++;
      case 0x7D:
        depth--;
        if (depth == 0) return html.substring(start, i + 1);
    }
  }
  throw const ApiParseError('pixiv bootstrap value object is truncated');
}

final _trailingComma = RegExp(r',(?=\s*[}\]])');

String _stripTrailingCommas(String object) =>
    object.replaceAll(_trailingComma, '');

NovelWebPayload _payload(Map<String, Object?> novel) {
  final navigation = readMap(novel['seriesNavigation']);
  return NovelWebPayload(
    text: readOptionalString(novel['text']),
    images: _imageUrls(readMap(novel['images'])),
    illustThumbs: _illustThumbs(readMap(novel['illusts'])),
    seriesPrevId: readPositiveInt(readMap(navigation['prevNovel'])['id']),
    seriesNextId: readPositiveInt(readMap(navigation['nextNovel'])['id']),
  );
}

Map<String, String> _imageUrls(Map<String, Object?> images) {
  final resolved = <String, String>{};
  for (final entry in images.entries) {
    final holder = entry.value;
    if (holder is! Map<String, dynamic>) continue;
    final urls = readMap(holder['urls']);
    final url =
        readOptionalString(urls['original']) ??
        urls.values.whereType<String>().firstOrNull;
    if (url != null) resolved[entry.key] = url;
  }
  return resolved;
}

Map<String, String> _illustThumbs(Map<String, Object?> illusts) {
  final resolved = <String, String>{};
  for (final entry in illusts.entries) {
    final holder = entry.value;
    if (holder is! Map<String, dynamic>) continue;
    final illust = readMap(holder['illust']);
    final images = readMap(illust['images']);
    final url = readFirstString(images, const ['medium', 'large', 'original']);
    if (url != null) resolved[entry.key] = url;
  }
  return resolved;
}
