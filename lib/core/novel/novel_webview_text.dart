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
    pixiv =
        jsonDecode(_stripTrailingCommas(_jsLiteralToJson(object)))
            as Map<String, dynamic>;
  } on FormatException catch (error) {
    throw ApiParseError(error);
  }
  final novel = pixiv['novel'];
  if (novel is! Map) {
    throw const ApiParseError('pixiv bootstrap object has no novel entry');
  }
  return _payload(readMap(novel));
}

/// Returns the `{…}` balanced-brace substring starting at [start]. Both
/// quote kinds are tracked — a `}` inside a '…' literal would otherwise end
/// the scan early.
String _balancedObject(String html, int start) {
  var depth = 0;
  var inString = 0; // 0 none, '"' double, '\'' single
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    final unit = html.codeUnitAt(i);
    if (inString != 0) {
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5C) {
        escaped = true;
      } else if (unit == inString) {
        inString = 0;
      }
      continue;
    }
    switch (unit) {
      case 0x22:
      case 0x27:
        inString = unit;
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

/// Normalizes the bootstrap `value:` payload from a JavaScript object
/// literal into strict JSON: unquoted keys get quoted ("sessionUserId:" is
/// what the real page ships), '…' strings become "…", and the JS-only
/// literals `undefined`/`NaN`/`Infinity` fold to null. Gson's lenient mode
/// — what Shaft's parser rides on — accepts all three; dart:convert does
/// not, which is why the strict decode died on the first unquoted key.
String _jsLiteralToJson(String source) {
  final out = StringBuffer();
  // Stack entry true = object, false = array.
  final stack = <bool>[];
  var expectKey = false;
  var i = 0;
  while (i < source.length) {
    final u = source.codeUnitAt(i);
    if (u == 0x22 || u == 0x27) {
      i = _emitString(source, i, out);
      continue;
    }
    switch (u) {
      case 0x7B: // {
        stack.add(true);
        expectKey = true;
        out.writeCharCode(u);
      case 0x5B: // [
        stack.add(false);
        expectKey = false;
        out.writeCharCode(u);
      case 0x7D: // }
      case 0x5D: // ]
        if (stack.isNotEmpty) stack.removeLast();
        expectKey = false;
        out.writeCharCode(u);
      case 0x2C: // ,
        expectKey = stack.isNotEmpty && stack.last;
        out.writeCharCode(u);
      case 0x3A: // :
        expectKey = false;
        out.writeCharCode(u);
      default:
        if (_isIdentStart(u)) {
          final start = i;
          while (i < source.length && _isIdentPart(source.codeUnitAt(i))) {
            i++;
          }
          final ident = source.substring(start, i);
          if (expectKey) {
            out.write('"$ident"');
          } else if (ident == 'undefined' ||
              ident == 'NaN' ||
              ident == 'Infinity') {
            out.write('null');
          } else {
            // true/false/null and number-adjacent identifiers pass through.
            out.write(ident);
          }
          continue;
        }
        out.writeCharCode(u);
    }
    i++;
  }
  return out.toString();
}

/// Emits the string literal at [start] ('"' or '\''-quoted) into [out] as a
/// double-quoted JSON string, returning the index just past it.
int _emitString(String source, int start, StringBuffer out) {
  final quote = source.codeUnitAt(start);
  out.writeCharCode(0x22);
  var i = start + 1;
  while (i < source.length) {
    final u = source.codeUnitAt(i);
    if (u == 0x5C && i + 1 < source.length) {
      final next = source.codeUnitAt(i + 1);
      if (next == 0x27 && quote == 0x27) {
        // \' inside a '…' literal is just an apostrophe in JSON.
        out.writeCharCode(0x27);
      } else {
        out.writeCharCode(0x5C);
        out.writeCharCode(next);
      }
      i += 2;
      continue;
    }
    if (u == quote) {
      out.writeCharCode(0x22);
      return i + 1;
    }
    if (u == 0x22) {
      // A bare " inside a '…' literal must be escaped for JSON.
      out.write(r'\"');
    } else {
      out.writeCharCode(u);
    }
    i++;
  }
  throw const ApiParseError('pixiv bootstrap value has an unterminated string');
}

bool _isIdentStart(int u) =>
    (u >= 0x41 && u <= 0x5A) ||
    (u >= 0x61 && u <= 0x7A) ||
    u == 0x5F ||
    u == 0x24;

bool _isIdentPart(int u) => _isIdentStart(u) || (u >= 0x30 && u <= 0x39);

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
