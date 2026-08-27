import 'dart:collection';
import 'package:flutter/material.dart';

import '../../core/network/api_error.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';

/// Text settings that participate in the layout cache key.
class NovelLayoutStyle {
  const NovelLayoutStyle({
    this.fontFamily,
    this.fontSize = 17,
    this.lineHeight = 1.7,
    this.fontWeight = FontWeight.w400,
    this.paragraphSpacing = 12,
    this.horizontalPadding = 24,
    this.verticalPadding = 22,
  });

  final String? fontFamily;
  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final double verticalPadding;

  TextStyle textStyle(Color color) => TextStyle(
    color: color,
    fontFamily: fontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    height: lineHeight,
  );
}

/// Position independent of a particular viewport's page count.
class NovelAnchor {
  const NovelAnchor({required this.paragraphId, required this.offset});

  final String paragraphId;
  final int offset;

  @override
  bool operator ==(Object other) {
    return other is NovelAnchor &&
        other.paragraphId == paragraphId &&
        other.offset == offset;
  }

  @override
  int get hashCode => Object.hash(paragraphId, offset);

  @override
  String toString() => 'NovelAnchor($paragraphId, $offset)';
}

typedef StableAnchor = NovelAnchor;

@immutable
class NovelLayoutKey {
  const NovelLayoutKey({
    required this.contentVersion,
    required this.viewport,
    required this.fontFamily,
    required this.fontSize,
    required this.lineHeight,
    required this.fontWeight,
    required this.brightness,
    required this.textDirection,
  });

  final String contentVersion;
  final Size viewport;
  final String? fontFamily;
  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;
  final Brightness brightness;
  final TextDirection textDirection;

  @override
  bool operator ==(Object other) {
    return other is NovelLayoutKey &&
        other.contentVersion == contentVersion &&
        other.viewport == viewport &&
        other.fontFamily == fontFamily &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.fontWeight == fontWeight &&
        other.brightness == brightness &&
        other.textDirection == textDirection;
  }

  @override
  int get hashCode => Object.hash(
    contentVersion,
    viewport,
    fontFamily,
    fontSize,
    lineHeight,
    fontWeight,
    brightness,
    textDirection,
  );
}

class NovelPageLine {
  const NovelPageLine({
    required this.text,
    required this.paragraphId,
    required this.startOffset,
    required this.endOffset,
    required this.height,
    required this.isParagraphEnd,
  });

  final String text;
  final String paragraphId;
  final int startOffset;
  final int endOffset;
  final double height;
  final bool isParagraphEnd;

  NovelAnchor get startAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: startOffset);

  NovelAnchor get endAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: endOffset);
}

class NovelLayoutPage {
  const NovelLayoutPage({
    required this.index,
    required this.lines,
    required this.startAnchor,
    required this.endAnchor,
    required this.startCharacter,
    required this.endCharacter,
  });

  final int index;
  final List<NovelPageLine> lines;
  final NovelAnchor startAnchor;
  final NovelAnchor endAnchor;
  final int startCharacter;
  final int endCharacter;

  String get text => lines.map((line) => line.text).join('\n');
}

class NovelLayout {
  const NovelLayout({
    required this.key,
    required this.pages,
    required this.totalCharacters,
    required List<String> paragraphOrder,
  }) : _paragraphOrder = paragraphOrder;

  final NovelLayoutKey key;
  final List<NovelLayoutPage> pages;
  final int totalCharacters;
  final List<String> _paragraphOrder;

  int pageIndexForAnchor(NovelAnchor anchor) {
    if (pages.isEmpty) return 0;
    // A page's own start wins over the previous page's inclusive end. This
    // matters when a relayout restores the anchor captured at a page edge.
    for (final page in pages) {
      if (anchor == page.startAnchor) return page.index;
    }
    for (final page in pages) {
      if (_compareAnchors(anchor, page.startAnchor) < 0) continue;
      if (_compareAnchors(anchor, page.endAnchor) <= 0) return page.index;
    }
    return pages.length - 1;
  }

  int pageIndexForCharacter(int characterOffset) {
    if (pages.isEmpty) return 0;
    final target = characterOffset.clamp(0, totalCharacters);
    for (final page in pages) {
      if (target <= page.endCharacter) return page.index;
    }
    return pages.length - 1;
  }

  double progressPercent(int pageIndex) {
    if (pages.length <= 1) return 100;
    final clamped = pageIndex.clamp(0, pages.length - 1);
    return clamped / (pages.length - 1) * 100;
  }

  int _compareAnchors(NovelAnchor left, NovelAnchor right) {
    final leftIndex = _paragraphOrder.indexOf(left.paragraphId);
    final rightIndex = _paragraphOrder.indexOf(right.paragraphId);
    final normalizedLeft = leftIndex < 0 ? 0 : leftIndex;
    final normalizedRight = rightIndex < 0 ? 0 : rightIndex;
    final paragraphComparison = normalizedLeft.compareTo(normalizedRight);
    if (paragraphComparison != 0) return paragraphComparison;
    return left.offset.compareTo(right.offset);
  }
}

/// Small LRU cache so rotation/font changes do not grow memory forever.
class NovelLayoutCache {
  NovelLayoutCache({this.maxEntries = 8}) : assert(maxEntries > 0);

  final int maxEntries;
  final LinkedHashMap<NovelLayoutKey, NovelLayout> _entries =
      LinkedHashMap<NovelLayoutKey, NovelLayout>();

  NovelLayout? get(NovelLayoutKey key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(NovelLayoutKey key, NovelLayout value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  int get length => _entries.length;

  bool containsKey(NovelLayoutKey key) => _entries.containsKey(key);

  void clear() => _entries.clear();
}

/// Calculates body pages without blocking the widget tree between paragraphs.
class NovelLayoutEngine {
  NovelLayoutEngine({NovelLayoutCache? cache})
    : cache = cache ?? NovelLayoutCache();

  final NovelLayoutCache cache;

  NovelLayout layout({
    required List<NovelParagraph> paragraphs,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final key = _key(
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      brightness: brightness,
      textDirection: textDirection,
    );
    final cached = cache.get(key);
    if (cached != null) return cached;
    final result = _build(
      paragraphs: paragraphs,
      key: key,
      style: style,
      textColor: textColor,
      textDirection: textDirection,
      cancelled: () => false,
    );
    cache.put(key, result);
    return result;
  }

  Future<NovelLayout> layoutCancellable({
    required List<NovelParagraph> paragraphs,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
    CancelToken? cancelToken,
  }) async {
    final key = _key(
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      brightness: brightness,
      textDirection: textDirection,
    );
    final cached = cache.get(key);
    if (cached != null) return cached;
    // Yield periodically between paragraphs. This lets a superseding
    // viewport/font calculation cancel before the result reaches the UI.
    final result = await _buildAsync(
      paragraphs: paragraphs,
      key: key,
      style: style,
      textColor: textColor,
      textDirection: textDirection,
      cancelToken: cancelToken,
    );
    cache.put(key, result);
    return result;
  }

  NovelLayoutKey _key({
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Brightness brightness,
    required TextDirection textDirection,
  }) {
    return NovelLayoutKey(
      contentVersion: contentVersion,
      viewport: viewport,
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      lineHeight: style.lineHeight,
      fontWeight: style.fontWeight,
      brightness: brightness,
      textDirection: textDirection,
    );
  }

  Future<NovelLayout> _buildAsync({
    required List<NovelParagraph> paragraphs,
    required NovelLayoutKey key,
    required NovelLayoutStyle style,
    required Color textColor,
    required TextDirection textDirection,
    required CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
    final lines = <_MeasuredLine>[];
    if (paragraphs.isEmpty) {
      lines.add(_MeasuredLine.empty());
    } else {
      for (var index = 0; index < paragraphs.length; index++) {
        if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
        lines.addAll(
          _measureParagraph(
            paragraphs[index],
            paragraphIndex: index,
            maxWidth: _maxWidth(key.viewport, style),
            style: style,
            textColor: textColor,
            textDirection: textDirection,
          ),
        );
        if (index % 8 == 7) {
          await Future<void>.delayed(Duration.zero);
          if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
        }
      }
    }
    return _paginate(
      lines: lines,
      paragraphs: paragraphs,
      key: key,
      style: style,
    );
  }

  NovelLayout _build({
    required List<NovelParagraph> paragraphs,
    required NovelLayoutKey key,
    required NovelLayoutStyle style,
    required Color textColor,
    required TextDirection textDirection,
    required bool Function() cancelled,
  }) {
    final lines = <_MeasuredLine>[];
    if (paragraphs.isEmpty) {
      lines.add(_MeasuredLine.empty());
    } else {
      for (var index = 0; index < paragraphs.length; index++) {
        if (cancelled()) throw const ApiCancelled();
        lines.addAll(
          _measureParagraph(
            paragraphs[index],
            paragraphIndex: index,
            maxWidth: _maxWidth(key.viewport, style),
            style: style,
            textColor: textColor,
            textDirection: textDirection,
          ),
        );
      }
    }
    return _paginate(
      lines: lines,
      paragraphs: paragraphs,
      key: key,
      style: style,
    );
  }

  List<_MeasuredLine> _measureParagraph(
    NovelParagraph paragraph, {
    required int paragraphIndex,
    required double maxWidth,
    required NovelLayoutStyle style,
    required Color textColor,
    required TextDirection textDirection,
  }) {
    final source = paragraph.text.isEmpty ? ' ' : paragraph.text;
    final painter = TextPainter(
      text: TextSpan(text: source, style: style.textStyle(textColor)),
      textDirection: textDirection,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: maxWidth);
    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) {
      return [
        _MeasuredLine(
          paragraphIndex: paragraphIndex,
          paragraphId: paragraph.id,
          startOffset: 0,
          endOffset: paragraph.text.length,
          text: paragraph.text,
          height: style.fontSize * style.lineHeight,
          isParagraphEnd: true,
        ),
      ];
    }
    return [
      for (var index = 0; index < metrics.length; index++)
        () {
          final metric = metrics[index];
          // Flutter's LineMetrics intentionally exposes geometry, not text
          // indices. Resolve each geometry row back to a line range through
          // TextPainter so UTF-16 offsets remain stable for anchor restore.
          final lineTop = metric.baseline - metric.ascent;
          final position = painter.getPositionForOffset(
            Offset(0, lineTop + 0.5),
          );
          final range = painter.getLineBoundary(position);
          final start = range.start.clamp(0, paragraph.text.length);
          final end = range.end.clamp(start, paragraph.text.length);
          return _MeasuredLine(
            paragraphIndex: paragraphIndex,
            paragraphId: paragraph.id,
            startOffset: start,
            endOffset: end,
            text: paragraph.text.substring(start, end),
            height: metric.height,
            isParagraphEnd: index == metrics.length - 1,
          );
        }(),
    ];
  }

  NovelLayout _paginate({
    required List<_MeasuredLine> lines,
    required List<NovelParagraph> paragraphs,
    required NovelLayoutKey key,
    required NovelLayoutStyle style,
  }) {
    final availableHeight = (key.viewport.height - style.verticalPadding * 2)
        .clamp(1.0, double.infinity);
    final pages = <NovelLayoutPage>[];
    final current = <_MeasuredLine>[];
    var currentHeight = 0.0;
    var paragraphBase = 0;
    var nextParagraph = 0;
    var startCharacter = 0;

    void flush() {
      if (current.isEmpty) return;
      final pageIndex = pages.length;
      final pageLines = [
        for (final line in current)
          NovelPageLine(
            text: line.text,
            paragraphId: line.paragraphId,
            startOffset: line.startOffset,
            endOffset: line.endOffset,
            height: line.height,
            isParagraphEnd: line.isParagraphEnd,
          ),
      ];
      final last = current.last;
      final endCharacter = _characterOffset(
        last,
        paragraphs,
        paragraphBase: paragraphBase,
      );
      pages.add(
        NovelLayoutPage(
          index: pageIndex,
          lines: List.unmodifiable(pageLines),
          startAnchor: current.first.startAnchor,
          endAnchor: last.endAnchor,
          startCharacter: startCharacter,
          endCharacter: endCharacter,
        ),
      );
      current.clear();
      currentHeight = 0;
      startCharacter = endCharacter;
    }

    for (final line in lines) {
      while (nextParagraph < line.paragraphIndex) {
        paragraphBase += paragraphs[nextParagraph].text.length + 1;
        nextParagraph++;
      }
      final spacing = line.isParagraphEnd ? style.paragraphSpacing : 0;
      final lineHeight = line.height + spacing;
      if (current.isNotEmpty && currentHeight + lineHeight > availableHeight) {
        flush();
      }
      current.add(line);
      currentHeight += lineHeight;
    }
    flush();
    if (pages.isEmpty) {
      final empty = NovelAnchor(paragraphId: 'p0', offset: 0);
      pages.add(
        NovelLayoutPage(
          index: 0,
          lines: const [
            NovelPageLine(
              text: '',
              paragraphId: 'p0',
              startOffset: 0,
              endOffset: 0,
              height: 0,
              isParagraphEnd: true,
            ),
          ],
          startAnchor: empty,
          endAnchor: empty,
          startCharacter: 0,
          endCharacter: 0,
        ),
      );
    }
    final totalCharacters = paragraphs.isEmpty
        ? 0
        : paragraphs.fold<int>(0, (total, item) => total + item.text.length) +
              paragraphs.length -
              1;
    return NovelLayout(
      key: key,
      pages: List.unmodifiable(pages),
      totalCharacters: totalCharacters,
      paragraphOrder: [for (final paragraph in paragraphs) paragraph.id],
    );
  }

  int _characterOffset(
    _MeasuredLine line,
    List<NovelParagraph> paragraphs, {
    required int paragraphBase,
  }) {
    return paragraphBase + line.endOffset;
  }

  double _maxWidth(Size viewport, NovelLayoutStyle style) =>
      (viewport.width - style.horizontalPadding * 2).clamp(
        1.0,
        double.infinity,
      );
}

class _MeasuredLine {
  const _MeasuredLine({
    required this.paragraphIndex,
    required this.paragraphId,
    required this.startOffset,
    required this.endOffset,
    required this.text,
    required this.height,
    required this.isParagraphEnd,
  });

  const _MeasuredLine.empty()
    : paragraphIndex = 0,
      paragraphId = 'p0',
      startOffset = 0,
      endOffset = 0,
      text = '',
      height = 0,
      isParagraphEnd = true;

  final int paragraphIndex;
  final String paragraphId;
  final int startOffset;
  final int endOffset;
  final String text;
  final double height;
  final bool isParagraphEnd;

  NovelAnchor get startAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: startOffset);

  NovelAnchor get endAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: endOffset);
}
