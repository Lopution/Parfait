/// Pixiv caption HTML → typed inline spans.
///
/// Pixiv 简介是 HTML。仓库不引入 HTML 解析依赖，这里实现最小、确定性的
/// 子集解析器（纯函数、无 I/O）：
///
/// - `<br>` / `<br/>` / `<br />` → 换行
/// - HTML 实体（`&lt; &gt; &amp; &quot; &#39; &nbsp;` 与数字实体）→ 解码
/// - `<a href="...">text</a>` → 链接 span（href 原样保留，由调用方决定
///   路由：站内 pixiv 链接走内部路由，其余走 outbound open-url）
/// - 任何其它标签被剥离但**保持可观察**：未知标签记录到
///   [IllustCaptionParse.unobservedTags]，绝不静默吞掉
///
/// 输出与 Flutter 解耦（不依赖 dart:ui）以便离线单测；调用方自行把
/// [CaptionSpan] 映射为 `TextSpan`。
library;

/// One parsed inline unit of a caption.
sealed class CaptionSpan {
  const CaptionSpan();
}

/// Plain text run.
class CaptionText extends CaptionSpan {
  const CaptionText(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is CaptionText && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// A newline introduced by `<br>`.
class CaptionBreak extends CaptionSpan {
  const CaptionBreak();

  @override
  bool operator ==(Object other) => other is CaptionBreak;

  @override
  int get hashCode => 0x1b02;
}

/// An `<a href>` run.
class CaptionLink extends CaptionSpan {
  const CaptionLink({required this.href, required this.text});

  final String href;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CaptionLink && other.href == href && other.text == text;

  @override
  int get hashCode => Object.hash(href, text);
}

/// Parse result: spans plus every tag the parser did not understand.
class IllustCaptionParse {
  const IllustCaptionParse({
    required this.spans,
    required this.unobservedTags,
  });

  final List<CaptionSpan> spans;

  /// Tag names (lowercased) that were stripped but not interpreted. Callers
  /// may surface these; the parser never silently discards them.
  final List<String> unobservedTags;
}

/// Parses a Pixiv caption fragment.
IllustCaptionParse parseIllustCaption(String html) {
  final spans = <CaptionSpan>[];
  final unobserved = <String>{};
  final buffer = StringBuffer();

  void flushText() {
    if (buffer.isEmpty) return;
    final decoded = _decodeEntities(buffer.toString());
    if (decoded.isNotEmpty) {
      spans.add(CaptionText(decoded));
    }
    buffer.clear();
  }

  var index = 0;
  while (index < html.length) {
    final open = html.indexOf('<', index);
    if (open < 0) {
      buffer.write(html.substring(index));
      index = html.length;
      continue;
    }
    if (open > index) {
      buffer.write(html.substring(index, open));
    }

    final close = html.indexOf('>', open);
    if (close < 0) {
      // Unclosed tag: keep the remainder as text (observable).
      buffer.write(html.substring(open));
      index = html.length;
      continue;
    }
    final tag = html.substring(open + 1, close).trim();
    index = close + 1;

    if (tag.isEmpty || tag.startsWith('!--')) {
      // Comments and empty constructs are stripped silently (they are not
      // content).
      continue;
    }

    final isClosing = tag.startsWith('/');
    var tagName = isClosing ? tag.substring(1) : tag;
    if (!isClosing && tagName.endsWith('/')) {
      // `<br/>` self-closing form.
      tagName = tagName.substring(0, tagName.length - 1);
    }
    // Tag name is the first token (`<span class=...>` -> `span`).
    tagName = tagName.split(RegExp(r'\s')).first.trim().toLowerCase();
    if (tagName.isEmpty) continue;

    if (!isClosing && (tagName == 'br')) {
      flushText();
      spans.add(const CaptionBreak());
      continue;
    }
    if (isClosing && (tagName == 'br')) {
      // `</br>` is invalid HTML but occurs in the wild; treat as a break.
      flushText();
      spans.add(const CaptionBreak());
      continue;
    }
    if (!isClosing && tagName == 'a') {
      final href = _extractHref(tag);
      // Consume until the matching `</a>`.
      final end = html.toLowerCase().indexOf('</a', index);
      final contentEnd = end < 0 ? html.length : end;
      final inner = html.substring(index, contentEnd);
      final linkText = _decodeEntities(_stripTags(inner));
      flushText();
      spans.add(CaptionLink(href: href, text: linkText));
      index = end < 0 ? html.length : html.indexOf('>', end) + 1;
      continue;
    }
    if (isClosing && tagName == 'a') {
      // A stray closing tag; nothing to open.
      continue;
    }

    // Any other tag: strip it, but record it.
    unobserved.add(tagName);
  }

  flushText();
  return IllustCaptionParse(
    spans: List.unmodifiable(spans),
    unobservedTags: unobserved.toList()..sort(),
  );
}

String _extractHref(String tag) {
  final match = RegExp(
    r"""href\s*=\s*["']([^"']+)["']""",
    caseSensitive: false,
  ).firstMatch(tag);
  return match?.group(1) ?? '';
}

/// Removes any remaining `<...>` fragments inside link text.
String _stripTags(String input) {
  return input.replaceAll(RegExp(r'<[^>]*>'), '');
}

/// Decodes the HTML entities present in Pixiv captions.
String _decodeEntities(String input) {
  if (!input.contains('&')) return input;
  final buffer = StringBuffer();
  var index = 0;
  while (index < input.length) {
    final amp = input.indexOf('&', index);
    if (amp < 0) {
      buffer.write(input.substring(index));
      break;
    }
    buffer.write(input.substring(index, amp));
    final semi = input.indexOf(';', amp);
    if (semi < 0 || semi - amp > 12) {
      // Not an entity; keep the ampersand literally.
      buffer.write('&');
      index = amp + 1;
      continue;
    }
    final entity = input.substring(amp + 1, semi);
    final decoded = _namedEntity(entity) ?? _numericEntity(entity);
    if (decoded == null) {
      buffer.write(input.substring(amp, semi + 1));
    } else {
      buffer.write(decoded);
    }
    index = semi + 1;
  }
  return buffer.toString();
}

String? _namedEntity(String entity) {
  return switch (entity.toLowerCase()) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    'apos' || 'lsquo' || 'rsquo' => "'",
    'nbsp' => '\u00a0',
    'hellip' => '…',
    'ndash' => '–',
    'mdash' => '—',
    'copy' => '©',
    'reg' => '®',
    'trade' => '™',
    'bull' => '•',
    'middot' => '·',
    'tilde' => '~',
    _ => null,
  };
}

String? _numericEntity(String entity) {
  if (entity.startsWith('#')) {
    final radix = entity.startsWith('#x') || entity.startsWith('#X') ? 16 : 10;
    final digits = entity.substring(radix == 16 ? 2 : 1);
    final code = int.tryParse(digits, radix: radix);
    if (code != null && code >= 0 && code <= 0x10ffff) {
      return String.fromCharCode(code);
    }
  }
  return null;
}