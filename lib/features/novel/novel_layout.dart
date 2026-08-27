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

/// Hard limits for one layout transaction. They make work proportional to a
/// caller-provided finite budget instead of allowing a malformed/huge novel
/// to create unbounded line and page state.
@immutable
class NovelLayoutBudget {
  const NovelLayoutBudget({
    this.maxParagraphs = 100000,
    this.maxTextUnits = 4 * 1024 * 1024,
    this.maxLines = 200000,
    this.maxPages = 100000,
    this.chunkParagraphs = 8,
  }) : assert(maxParagraphs > 0),
       assert(maxTextUnits > 0),
       assert(maxLines > 0),
       assert(maxPages > 0),
       assert(chunkParagraphs > 0);

  final int maxParagraphs;
  final int maxTextUnits;
  final int maxLines;
  final int maxPages;
  final int chunkParagraphs;
}

@immutable
class NovelLayoutProgress {
  const NovelLayoutProgress({
    required this.processedParagraphs,
    required this.totalParagraphs,
    required this.measuredLines,
    required this.pages,
    required this.isComplete,
  });

  final int processedParagraphs;
  final int totalParagraphs;
  final int measuredLines;
  final int pages;
  final bool isComplete;

  double get fraction {
    if (totalParagraphs <= 0) return isComplete ? 1 : 0;
    return (processedParagraphs / totalParagraphs).clamp(0.0, 1.0);
  }

  double get progress => fraction;
}

class NovelLayoutBudgetExceeded implements Exception {
  const NovelLayoutBudgetExceeded({
    required this.budgetName,
    required this.actual,
    required this.limit,
  });

  final String budgetName;
  final int actual;
  final int limit;

  @override
  String toString() =>
      'NovelLayoutBudgetExceeded($budgetName: $actual > $limit)';
}

typedef NovelLayoutProgressCallback = void Function(NovelLayoutProgress);

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
    this.chapterTitle,
  });

  final int index;
  final List<NovelPageLine> lines;
  final NovelAnchor startAnchor;
  final NovelAnchor endAnchor;
  final int startCharacter;
  final int endCharacter;
  final String? chapterTitle;

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
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) {
    final key = _key(
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      brightness: brightness,
      textDirection: textDirection,
    );
    final cached = cache.get(key);
    if (cached != null) {
      onProgress?.call(_completeProgress(paragraphs, cached));
      return cached;
    }
    final result = _build(
      paragraphs: paragraphs,
      key: key,
      style: style,
      textColor: textColor,
      textDirection: textDirection,
      cancelled: () => false,
      budget: budget,
      onProgress: onProgress,
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
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) async {
    final key = _key(
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      brightness: brightness,
      textDirection: textDirection,
    );
    final cached = cache.get(key);
    if (cached != null) {
      onProgress?.call(_completeProgress(paragraphs, cached));
      return cached;
    }
    // Yield periodically between paragraphs. This lets a superseding
    // viewport/font calculation cancel before the result reaches the UI.
    final result = await _buildAsync(
      paragraphs: paragraphs,
      key: key,
      style: style,
      textColor: textColor,
      textDirection: textDirection,
      cancelToken: cancelToken,
      budget: budget,
      onProgress: onProgress,
    );
    cache.put(key, result);
    return result;
  }

  NovelLayout layoutDocument({
    required NovelMarkupDocument document,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) {
    return layout(
      paragraphs: _paragraphsForDocument(document),
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      textColor: textColor,
      brightness: brightness,
      textDirection: textDirection,
      budget: budget,
      onProgress: onProgress,
    );
  }

  Future<NovelLayout> layoutDocumentCancellable({
    required NovelMarkupDocument document,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
    CancelToken? cancelToken,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) {
    return layoutCancellable(
      paragraphs: _paragraphsForDocument(document),
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      textColor: textColor,
      brightness: brightness,
      textDirection: textDirection,
      cancelToken: cancelToken,
      budget: budget,
      onProgress: onProgress,
    );
  }

  List<NovelParagraph> _paragraphsForDocument(NovelMarkupDocument document) {
    final paragraphs = <NovelParagraph>[];
    var pendingPageBreak = false;
    for (final block in document.blocks) {
      switch (block) {
        case NovelParagraph():
          final paragraph = block;
          if (pendingPageBreak) {
            paragraphs.add(
              NovelParagraph(
                id: paragraph.id,
                text: paragraph.text,
                inlineMarks: paragraph.inlineMarks,
                tokens: paragraph.tokens,
                pageBreakBefore: true,
                isChapterHeading: paragraph.isChapterHeading,
              ),
            );
            pendingPageBreak = false;
          } else {
            paragraphs.add(paragraph);
          }
        case NovelPageBreakBlock():
          pendingPageBreak = true;
        case NovelChapterBlock():
          paragraphs.add(
            NovelParagraph(
              id: block.id,
              text: block.title,
              tokens: [block.token],
              pageBreakBefore: true,
              isChapterHeading: true,
            ),
          );
          pendingPageBreak = false;
      }
    }
    if (pendingPageBreak) {
      paragraphs.add(
        const NovelParagraph(
          id: 'page-break-end',
          text: '',
          pageBreakBefore: true,
        ),
      );
    }
    if (paragraphs.isEmpty) {
      paragraphs.add(const NovelParagraph(id: 'p0', text: ''));
    }
    return paragraphs;
  }

  static void _checkBudget(
    List<NovelParagraph> paragraphs,
    NovelLayoutBudget budget,
  ) {
    if (paragraphs.length > budget.maxParagraphs) {
      throw NovelLayoutBudgetExceeded(
        budgetName: 'maxParagraphs',
        actual: paragraphs.length,
        limit: budget.maxParagraphs,
      );
    }
    final textUnits = paragraphs.fold<int>(
      0,
      (total, paragraph) => total + paragraph.text.length,
    );
    if (textUnits > budget.maxTextUnits) {
      throw NovelLayoutBudgetExceeded(
        budgetName: 'maxTextUnits',
        actual: textUnits,
        limit: budget.maxTextUnits,
      );
    }
  }

  static NovelLayoutProgress _completeProgress(
    List<NovelParagraph> paragraphs,
    NovelLayout layout,
  ) {
    return NovelLayoutProgress(
      processedParagraphs: paragraphs.length,
      totalParagraphs: paragraphs.length,
      measuredLines: layout.pages.fold<int>(
        0,
        (total, page) => total + page.lines.length,
      ),
      pages: layout.pages.length,
      isComplete: true,
    );
  }

  static void _reportProgress(
    NovelLayoutProgressCallback? callback, {
    required int processedParagraphs,
    required int totalParagraphs,
    required int measuredLines,
    required int pages,
    bool isComplete = false,
  }) {
    callback?.call(
      NovelLayoutProgress(
        processedParagraphs: processedParagraphs,
        totalParagraphs: totalParagraphs,
        measuredLines: measuredLines,
        pages: pages,
        isComplete: isComplete,
      ),
    );
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
    required NovelLayoutBudget budget,
    required NovelLayoutProgressCallback? onProgress,
  }) async {
    if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
    _checkBudget(paragraphs, budget);
    final lines = <_MeasuredLine>[];
    if (paragraphs.isEmpty) {
      lines.add(_MeasuredLine.empty());
    } else {
      for (var index = 0; index < paragraphs.length; index++) {
        if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
        final measured = _measureParagraph(
          paragraphs[index],
          paragraphIndex: index,
          maxWidth: _maxWidth(key.viewport, style),
          style: style,
          textColor: textColor,
          textDirection: textDirection,
        );
        lines.addAll(measured);
        if (lines.length > budget.maxLines) {
          throw NovelLayoutBudgetExceeded(
            budgetName: 'maxLines',
            actual: lines.length,
            limit: budget.maxLines,
          );
        }
        if ((index + 1) % budget.chunkParagraphs == 0 ||
            index == paragraphs.length - 1) {
          _reportProgress(
            onProgress,
            processedParagraphs: index + 1,
            totalParagraphs: paragraphs.length,
            measuredLines: lines.length,
            pages: 0,
          );
          await Future<void>.delayed(Duration.zero);
          if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
        }
      }
    }
    final result = _paginate(
      lines: lines,
      paragraphs: paragraphs,
      key: key,
      style: style,
      budget: budget,
      cancelled: () => cancelToken?.isCancelled ?? false,
    );
    _reportProgress(
      onProgress,
      processedParagraphs: paragraphs.length,
      totalParagraphs: paragraphs.length,
      measuredLines: lines.length,
      pages: result.pages.length,
      isComplete: true,
    );
    return result;
  }

  NovelLayout _build({
    required List<NovelParagraph> paragraphs,
    required NovelLayoutKey key,
    required NovelLayoutStyle style,
    required Color textColor,
    required TextDirection textDirection,
    required bool Function() cancelled,
    required NovelLayoutBudget budget,
    required NovelLayoutProgressCallback? onProgress,
  }) {
    _checkBudget(paragraphs, budget);
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
        if (lines.length > budget.maxLines) {
          throw NovelLayoutBudgetExceeded(
            budgetName: 'maxLines',
            actual: lines.length,
            limit: budget.maxLines,
          );
        }
        if ((index + 1) % budget.chunkParagraphs == 0 ||
            index == paragraphs.length - 1) {
          _reportProgress(
            onProgress,
            processedParagraphs: index + 1,
            totalParagraphs: paragraphs.length,
            measuredLines: lines.length,
            pages: 0,
          );
        }
      }
    }
    final result = _paginate(
      lines: lines,
      paragraphs: paragraphs,
      key: key,
      style: style,
      budget: budget,
      cancelled: cancelled,
    );
    _reportProgress(
      onProgress,
      processedParagraphs: paragraphs.length,
      totalParagraphs: paragraphs.length,
      measuredLines: lines.length,
      pages: result.pages.length,
      isComplete: true,
    );
    return result;
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
          pageBreakBefore: paragraph.pageBreakBefore,
          chapterTitle: paragraph.isChapterHeading ? paragraph.text : null,
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
            pageBreakBefore: index == 0 && paragraph.pageBreakBefore,
            chapterTitle: index == 0 && paragraph.isChapterHeading
                ? paragraph.text
                : null,
          );
        }(),
    ];
  }

  NovelLayout _paginate({
    required List<_MeasuredLine> lines,
    required List<NovelParagraph> paragraphs,
    required NovelLayoutKey key,
    required NovelLayoutStyle style,
    required NovelLayoutBudget budget,
    required bool Function() cancelled,
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
      if (pages.length >= budget.maxPages) {
        throw NovelLayoutBudgetExceeded(
          budgetName: 'maxPages',
          actual: pages.length + 1,
          limit: budget.maxPages,
        );
      }
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
          chapterTitle: current.first.chapterTitle,
        ),
      );
      current.clear();
      currentHeight = 0;
      startCharacter = endCharacter;
    }

    for (final line in lines) {
      if (cancelled()) throw const ApiCancelled();
      while (nextParagraph < line.paragraphIndex) {
        paragraphBase += paragraphs[nextParagraph].text.length + 1;
        nextParagraph++;
      }
      final spacing = line.isParagraphEnd ? style.paragraphSpacing : 0;
      final lineHeight = line.height + spacing;
      if (line.pageBreakBefore && current.isNotEmpty) {
        flush();
      }
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
    this.pageBreakBefore = false,
    this.chapterTitle,
  });

  const _MeasuredLine.empty()
    : paragraphIndex = 0,
      paragraphId = 'p0',
      startOffset = 0,
      endOffset = 0,
      text = '',
      height = 0,
      isParagraphEnd = true,
      pageBreakBefore = false,
      chapterTitle = null;

  final int paragraphIndex;
  final String paragraphId;
  final int startOffset;
  final int endOffset;
  final String text;
  final double height;
  final bool isParagraphEnd;
  final bool pageBreakBefore;
  final String? chapterTitle;

  NovelAnchor get startAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: startOffset);

  NovelAnchor get endAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: endOffset);
}
