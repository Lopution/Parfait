import 'dart:collection';
import 'package:material_ui/material_ui.dart';

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
    this.translationGap = 4,
  });

  final String? fontFamily;
  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final double verticalPadding;

  /// Space between a paragraph and its translation (bilingual reading).
  final double translationGap;

  /// A translation reads a step smaller and lighter than its paragraph.
  static const double _translationScale = 0.9;
  static const double _translationAlpha = 0.7;

  TextStyle textStyle(Color color) => TextStyle(
    color: color,
    fontFamily: fontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    height: lineHeight,
  );

  TextStyle translationStyle(Color color) => TextStyle(
    color: color.withValues(alpha: _translationAlpha),
    fontFamily: fontFamily,
    fontSize: fontSize * _translationScale,
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
    required this.spacingAfter,
    this.isTranslation = false,
  });

  final String text;
  final String paragraphId;
  final int startOffset;
  final int endOffset;
  final double height;
  final bool isParagraphEnd;

  /// Blank space below the line: the paragraph spacing after a paragraph,
  /// the translation gap between a paragraph and its translation.
  final double spacingAfter;

  /// A line of a paragraph's translation. It belongs to the paragraph and
  /// sits at its end (both offsets are the paragraph's length), so anchors
  /// and progress never point into a translation.
  final bool isTranslation;

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

  /// Measured lines of the latest text/width signature, by paragraph and
  /// by translation: a relayout that only adds translations measures
  /// nothing but the new ones.
  Object? _measureSignature;
  final Map<Object, List<_MeasuredLine>> _measured = {};

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
      contentVersion: contentVersion,
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

  /// [translations] (paragraph id → translation; an empty one shows
  /// nothing) lays each translation out under its paragraph.
  Future<NovelLayout> layoutCancellable({
    required List<NovelParagraph> paragraphs,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
    Map<String, String> translations = const {},
    CancelToken? cancelToken,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) async {
    final key = _key(
      contentVersion: _versionWith(contentVersion, translations),
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
      contentVersion: contentVersion,
      translations: translations,
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
    Map<String, String> translations = const {},
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
      translations: translations,
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

  /// The cache identity of a body laid out with [translations].
  static String _versionWith(
    String contentVersion,
    Map<String, String> translations,
  ) {
    if (translations.isEmpty) return contentVersion;
    final digest = Object.hashAllUnordered([
      for (final entry in translations.entries)
        Object.hash(entry.key, entry.value),
    ]);
    return '$contentVersion+${translations.length}:$digest';
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
    required String contentVersion,
    required Map<String, String> translations,
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
      final measure = _Measure(
        signature: _signature(contentVersion, key, style),
        maxWidth: _maxWidth(key.viewport, style),
        style: style,
        textColor: textColor,
        textDirection: textDirection,
      );
      for (var index = 0; index < paragraphs.length; index++) {
        if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
        final paragraph = paragraphs[index];
        lines.addAll(_measureCached(measure, paragraph, index));
        final translation = translations[paragraph.id];
        if (translation != null && translation.isNotEmpty) {
          lines.addAll(
            _measureTranslationCached(measure, paragraph, index, translation),
          );
        }
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
    required String contentVersion,
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
      final measure = _Measure(
        signature: _signature(contentVersion, key, style),
        maxWidth: _maxWidth(key.viewport, style),
        style: style,
        textColor: textColor,
        textDirection: textDirection,
      );
      for (var index = 0; index < paragraphs.length; index++) {
        if (cancelled()) throw const ApiCancelled();
        lines.addAll(_measureCached(measure, paragraphs[index], index));
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

  /// What decides how a text wraps: the body, the measure width and the
  /// type. Color and brightness only paint.
  Object _signature(
    String contentVersion,
    NovelLayoutKey key,
    NovelLayoutStyle style,
  ) => (
    contentVersion,
    _maxWidth(key.viewport, style),
    key.fontFamily,
    key.fontSize,
    key.lineHeight,
    key.fontWeight,
    key.textDirection,
  );

  List<_MeasuredLine> _cached(
    _Measure measure,
    Object key,
    List<_MeasuredLine> Function() measureLines,
  ) {
    if (measure.signature != _measureSignature) {
      _measureSignature = measure.signature;
      _measured.clear();
    }
    return _measured.putIfAbsent(key, measureLines);
  }

  List<_MeasuredLine> _measureCached(
    _Measure measure,
    NovelParagraph paragraph,
    int paragraphIndex,
  ) => _cached(measure, (
    paragraphIndex,
    paragraph.id,
  ), () => _measureParagraph(paragraph, paragraphIndex, measure));

  List<_MeasuredLine> _measureTranslationCached(
    _Measure measure,
    NovelParagraph paragraph,
    int paragraphIndex,
    String translation,
  ) => _cached(
    measure,
    (paragraph.id, translation),
    () => _measureTranslation(paragraph, paragraphIndex, translation, measure),
  );

  List<_MeasuredLine> _measureParagraph(
    NovelParagraph paragraph,
    int paragraphIndex,
    _Measure measure,
  ) {
    final style = measure.style;
    final source = paragraph.text.isEmpty ? ' ' : paragraph.text;
    final rows = _rows(source, style.textStyle(measure.textColor), measure);
    if (rows.isEmpty) {
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
    final length = paragraph.text.length;
    return [
      for (final (index, row) in rows.indexed)
        () {
          final start = row.start.clamp(0, length);
          final end = row.end.clamp(start, length);
          return _MeasuredLine(
            paragraphIndex: paragraphIndex,
            paragraphId: paragraph.id,
            startOffset: start,
            endOffset: end,
            text: paragraph.text.substring(start, end),
            height: row.height,
            isParagraphEnd: index == rows.length - 1,
            pageBreakBefore: index == 0 && paragraph.pageBreakBefore,
            chapterTitle: index == 0 && paragraph.isChapterHeading
                ? paragraph.text
                : null,
          );
        }(),
    ];
  }

  /// [translation]'s lines, anchored at the end of [paragraph].
  List<_MeasuredLine> _measureTranslation(
    NovelParagraph paragraph,
    int paragraphIndex,
    String translation,
    _Measure measure,
  ) {
    final rows = _rows(
      translation,
      measure.style.translationStyle(measure.textColor),
      measure,
    );
    final end = paragraph.text.length;
    return [
      for (final (index, row) in rows.indexed)
        _MeasuredLine(
          paragraphIndex: paragraphIndex,
          paragraphId: paragraph.id,
          startOffset: end,
          endOffset: end,
          text: translation.substring(row.start, row.end),
          height: row.height,
          isParagraphEnd: index == rows.length - 1,
          isTranslation: true,
        ),
    ];
  }

  /// The rows [text] wraps into at the measure width: each row's UTF-16
  /// range in [text] and its height.
  List<({int start, int end, double height})> _rows(
    String text,
    TextStyle style,
    _Measure measure,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: measure.textDirection,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: measure.maxWidth);
    final rows = [
      for (final metric in painter.computeLineMetrics())
        () {
          // Flutter's LineMetrics intentionally exposes geometry, not text
          // indices. Resolve each geometry row back to a line range through
          // TextPainter so UTF-16 offsets remain stable for anchor restore.
          final lineTop = metric.baseline - metric.ascent;
          final position = painter.getPositionForOffset(
            Offset(0, lineTop + 0.5),
          );
          final range = painter.getLineBoundary(position);
          final start = range.start.clamp(0, text.length);
          return (
            start: start,
            end: range.end.clamp(start, text.length),
            height: metric.height,
          );
        }(),
    ];
    painter.dispose();
    return rows;
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
    final current = <({_MeasuredLine line, double spacing})>[];
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
        for (final (:line, :spacing) in current)
          NovelPageLine(
            text: line.text,
            paragraphId: line.paragraphId,
            startOffset: line.startOffset,
            endOffset: line.endOffset,
            height: line.height,
            isParagraphEnd: line.isParagraphEnd,
            spacingAfter: spacing,
            isTranslation: line.isTranslation,
          ),
      ];
      final first = current.first.line;
      final last = current.last.line;
      final endCharacter = _characterOffset(
        last,
        paragraphs,
        paragraphBase: paragraphBase,
      );
      pages.add(
        NovelLayoutPage(
          index: pageIndex,
          lines: List.unmodifiable(pageLines),
          startAnchor: first.startAnchor,
          endAnchor: last.endAnchor,
          startCharacter: startCharacter,
          endCharacter: endCharacter,
          chapterTitle: first.chapterTitle,
        ),
      );
      current.clear();
      currentHeight = 0;
      startCharacter = endCharacter;
    }

    for (final (index, line) in lines.indexed) {
      if (cancelled()) throw const ApiCancelled();
      while (nextParagraph < line.paragraphIndex) {
        paragraphBase += paragraphs[nextParagraph].text.length + 1;
        nextParagraph++;
      }
      final next = index + 1 < lines.length ? lines[index + 1] : null;
      final spacing = _spacingAfter(line, next, style);
      final lineHeight = line.height + spacing;
      if (line.pageBreakBefore && current.isNotEmpty) {
        flush();
      }
      if (current.isNotEmpty && currentHeight + lineHeight > availableHeight) {
        flush();
      }
      current.add((line: line, spacing: spacing));
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
              spacingAfter: 0,
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

  /// Paragraph spacing after a paragraph — after its translation when it
  /// has one, with the smaller translation gap between the two.
  static double _spacingAfter(
    _MeasuredLine line,
    _MeasuredLine? next,
    NovelLayoutStyle style,
  ) {
    if (!line.isParagraphEnd) return 0;
    final translationFollows =
        !line.isTranslation &&
        next != null &&
        next.isTranslation &&
        next.paragraphIndex == line.paragraphIndex;
    return translationFollows ? style.translationGap : style.paragraphSpacing;
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
    this.isTranslation = false,
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
      chapterTitle = null,
      isTranslation = false;

  final int paragraphIndex;
  final String paragraphId;
  final int startOffset;
  final int endOffset;
  final String text;
  final double height;
  final bool isParagraphEnd;
  final bool pageBreakBefore;
  final String? chapterTitle;
  final bool isTranslation;

  NovelAnchor get startAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: startOffset);

  NovelAnchor get endAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: endOffset);
}

/// One layout's measuring inputs.
class _Measure {
  const _Measure({
    required this.signature,
    required this.maxWidth,
    required this.style,
    required this.textColor,
    required this.textDirection,
  });

  /// Lines measured under an equal signature wrap the same way.
  final Object signature;
  final double maxWidth;
  final NovelLayoutStyle style;
  final Color textColor;
  final TextDirection textDirection;
}
