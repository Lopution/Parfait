import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../../core/network/api_error.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';

/// Text settings that participate in the layout cache key.
class NovelLayoutStyle {
  const NovelLayoutStyle({
    this.fontFamily,
    this.fontFamilyFallback,
    this.fontSize = 17,
    this.lineHeight = 1.7,
    this.fontWeight = FontWeight.w400,
    this.paragraphSpacing = 12,
    this.horizontalPadding = 24,
    this.verticalPadding = 22,
    this.translationGap = 4,
  });

  /// The family and fallbacks the lines would take from the ambient style
  /// (the theme's), named so they are measured as they paint (LAYOUT-04).
  final String? fontFamily;
  final List<String>? fontFamilyFallback;
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

  /// A heading reads a third larger than the body, bold and set tighter.
  static const double _headingScale = 1.35;
  static const double _headingHeight = 1.35;

  /// The lines set their own letter spacing and leading: a measurement
  /// sees no ambient style, and a painted line would take the theme's
  /// (Material's dense type for CJK spaces its letters and spreads its
  /// leading evenly), run wider or taller than it was measured and lose
  /// its tail or its descenders (LAYOUT-04).
  TextStyle textStyle(Color color) => TextStyle(
    color: color,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    height: lineHeight,
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.even,
  );

  TextStyle translationStyle(Color color) => TextStyle(
    color: color.withValues(alpha: _translationAlpha),
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize * _translationScale,
    fontWeight: fontWeight,
    height: lineHeight,
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.even,
  );

  TextStyle headingStyle(Color color) => TextStyle(
    color: color,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize * _headingScale,
    fontWeight: FontWeight.w700,
    height: _headingHeight,
    letterSpacing: 0,
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// Below the title block: a blank line and the paragraph spacing, the
  /// break an author makes between passages.
  double get titleBlockGap => fontSize * lineHeight + paragraphSpacing;

  /// In the scroll mode, the space before a chapter, and around the rule
  /// an author's `[newpage]` becomes; the blank lines authors set around
  /// the marker add to it.
  double get chapterGap => titleBlockGap;
  double get pageBreakGap => titleBlockGap;

  /// The style a line of [kind] is measured and painted with (LAYOUT-04).
  TextStyle lineStyle(NovelLineKind kind, Color color) => switch (kind) {
    // An image line has no text; it takes the body's.
    NovelLineKind.body || NovelLineKind.image => textStyle(color),
    NovelLineKind.translation => translationStyle(color),
    NovelLineKind.heading || NovelLineKind.title => headingStyle(color),
    // A byline reads as a translation does: a step smaller and lighter.
    NovelLineKind.byline => translationStyle(color),
  };
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
    this.fontFamilyFallback,
    required this.fontSize,
    required this.lineHeight,
    required this.fontWeight,
    required this.brightness,
    required this.textDirection,
    this.textScaler = TextScaler.noScaling,
  });

  final String contentVersion;
  final Size viewport;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final double fontSize;
  final double lineHeight;
  final FontWeight fontWeight;
  final Brightness brightness;
  final TextDirection textDirection;

  /// The text scaler the page paints with, so each row is measured as
  /// wide as it is drawn (LAYOUT-04).
  final TextScaler textScaler;

  @override
  bool operator ==(Object other) {
    return other is NovelLayoutKey &&
        other.contentVersion == contentVersion &&
        other.viewport == viewport &&
        other.fontFamily == fontFamily &&
        listEquals(other.fontFamilyFallback, fontFamilyFallback) &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.fontWeight == fontWeight &&
        other.brightness == brightness &&
        other.textDirection == textDirection &&
        other.textScaler == textScaler;
  }

  @override
  int get hashCode => Object.hash(
    contentVersion,
    viewport,
    fontFamily,
    fontFamilyFallback == null ? null : Object.hashAll(fontFamilyFallback!),
    fontSize,
    lineHeight,
    fontWeight,
    brightness,
    textDirection,
    textScaler,
  );
}

/// What a laid-out line is, which picks the style it paints with.
enum NovelLineKind {
  body,

  /// A line of a paragraph's translation (bilingual reading).
  translation,

  /// A line of a chapter heading.
  heading,

  /// A line of the title block's title, then of its byline. Both carry the
  /// first paragraph's id with both offsets 0, so anchors, progress and
  /// characters never point into the title block.
  title,
  byline,

  /// An illustration, alone on its page ([NovelPageLine.image]). It carries
  /// its block's paragraph id with both offsets 0 and no text.
  image,
}

/// A pixiv novel's title and byline, laid out at the top of its first page.
@immutable
class NovelTitleBlock {
  const NovelTitleBlock({required this.title, required this.byline});

  final String title;

  /// The author, and the series when there is one.
  final String byline;

  @override
  bool operator ==(Object other) =>
      other is NovelTitleBlock &&
      other.title == title &&
      other.byline == byline;

  @override
  int get hashCode => Object.hash(title, byline);
}

/// Where an author's link goes: a Pixiv page of the novel (`[jump:N]`),
/// or a Pixiv address (`[[jumpuri:label > URL]]`).
typedef NovelLinkTarget = ({int? page, Uri? uri});

/// A link on a line: its range in the line's text and its target.
typedef NovelLineLink = ({int start, int end, NovelLinkTarget target});

/// The label a page jump without one of its own shows, in the reader's
/// language.
typedef NovelJumpLabel = String Function(int page);

class NovelPageLine {
  const NovelPageLine({
    required this.text,
    required this.paragraphId,
    required this.startOffset,
    required this.endOffset,
    required this.height,
    required this.isParagraphEnd,
    required this.spacingAfter,
    this.kind = NovelLineKind.body,
    this.image,
    this.links = const [],
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

  final NovelLineKind kind;

  /// The illustration of an [NovelLineKind.image] line; its height is the
  /// page's.
  final NovelImageLoadRequest? image;

  /// The author's links on this line, in order.
  final List<NovelLineLink> links;

  /// A line of a paragraph's translation. It belongs to the paragraph and
  /// sits at its end (both offsets are the paragraph's length), so anchors
  /// and progress never point into a translation.
  bool get isTranslation => kind == NovelLineKind.translation;

  bool get isTitleBlock =>
      kind == NovelLineKind.title || kind == NovelLineKind.byline;

  NovelAnchor get startAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: startOffset);

  NovelAnchor get endAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: endOffset);
}

/// Why a page begins where it does.
enum NovelPageBreak {
  /// The last page ran out, or the page holds an image.
  none,

  /// The author wrote `[newpage]`.
  newPage,

  /// A chapter opens it.
  chapter,
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
    this.breakBefore = NovelPageBreak.none,
  });

  final int index;
  final List<NovelPageLine> lines;
  final NovelAnchor startAnchor;
  final NovelAnchor endAnchor;
  final int startCharacter;
  final int endCharacter;
  final String? chapterTitle;
  final NovelPageBreak breakBefore;

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

/// One item of the scroll mode's column: a line, or the gap before a page
/// a chapter or the author's `[newpage]` begins ([gap] says which).
typedef NovelScrollItem = ({NovelPageLine? line, NovelPageBreak gap, int page});

/// The pages' lines as one column, for the scroll mode. A page that ran on
/// from the last continues it; a chapter starts after a gap, a `[newpage]`
/// after a divider. Every item's extent is known, so offsets, items and
/// anchors map to each other without measuring.
class NovelScrollColumn {
  factory NovelScrollColumn(NovelLayout layout, NovelLayoutStyle style) {
    final items = <NovelScrollItem>[];
    final extents = <double>[];
    final starts = <double>[0];
    final pageStarts = <int>[];
    void add(NovelScrollItem item, double extent) {
      items.add(item);
      extents.add(extent);
      starts.add(starts.last + extent);
    }

    for (final page in layout.pages) {
      if (page.index > 0) {
        switch (page.breakBefore) {
          case NovelPageBreak.newPage:
            add((
              line: null,
              gap: NovelPageBreak.newPage,
              page: page.index,
            ), style.pageBreakGap);
          case NovelPageBreak.chapter:
            add((
              line: null,
              gap: NovelPageBreak.chapter,
              page: page.index,
            ), style.chapterGap);
          case NovelPageBreak.none:
        }
      }
      pageStarts.add(items.length);
      for (final line in page.lines) {
        add((
          line: line,
          gap: NovelPageBreak.none,
          page: page.index,
        ), line.height + line.spacingAfter);
      }
    }
    return NovelScrollColumn._(layout, items, extents, starts, pageStarts);
  }

  NovelScrollColumn._(
    this.layout,
    this.items,
    this._extents,
    this._starts,
    this._pageStarts,
  );

  final NovelLayout layout;
  final List<NovelScrollItem> items;

  final List<double> _extents;

  /// Each item's top, then the column's height.
  final List<double> _starts;

  /// Each page's first line.
  final List<int> _pageStarts;

  double get extent => _starts.last;

  double extentAt(int index) => _extents[index];

  double offsetOf(int index) => _starts[index];

  /// The first line of [page].
  int itemOfPage(int page) =>
      _pageStarts[page.clamp(0, _pageStarts.length - 1)];

  /// The item at [offset] from the column's top.
  int itemAt(double offset) {
    var low = 0;
    var high = items.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// Where the column reads from [index]: a gap reads as the line after it.
  NovelAnchor anchorAt(int index) {
    for (var item = index; item < items.length; item++) {
      if (items[item].line case final line?) return line.startAnchor;
    }
    return layout.pages.last.endAnchor;
  }

  /// The line [anchor] names: the last of its paragraph's text lines that
  /// starts at or before it, on the page that holds it. A page's own start
  /// is its first line, the title block included.
  int itemForAnchor(NovelAnchor anchor) {
    final page = layout.pageIndexForAnchor(anchor);
    var found = itemOfPage(page);
    if (anchor == layout.pages[page].startAnchor) return found;
    for (var item = found; item < items.length; item++) {
      if (items[item].page != page) break;
      final line = items[item].line;
      if (line == null ||
          line.isTranslation ||
          line.isTitleBlock ||
          line.paragraphId != anchor.paragraphId) {
        continue;
      }
      if (line.startOffset <= anchor.offset) found = item;
    }
    return found;
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
    TextScaler textScaler = TextScaler.noScaling,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) {
    final key = _key(
      contentVersion: contentVersion,
      viewport: viewport,
      style: style,
      brightness: brightness,
      textDirection: textDirection,
      textScaler: textScaler,
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
  /// nothing) lays each translation out under its paragraph; [titleBlock]
  /// opens the first page.
  Future<NovelLayout> layoutCancellable({
    required List<NovelParagraph> paragraphs,
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Color textColor,
    required Brightness brightness,
    TextDirection textDirection = TextDirection.ltr,
    TextScaler textScaler = TextScaler.noScaling,
    Map<String, String> translations = const {},
    NovelTitleBlock? titleBlock,
    CancelToken? cancelToken,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
  }) async {
    final key = _key(
      contentVersion: _versionWith(contentVersion, translations, titleBlock),
      viewport: viewport,
      style: style,
      brightness: brightness,
      textDirection: textDirection,
      textScaler: textScaler,
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
      titleBlock: titleBlock,
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
    TextScaler textScaler = TextScaler.noScaling,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
    NovelJumpLabel? jumpLabel,
  }) {
    return layout(
      paragraphs: _paragraphsForDocument(document, jumpLabel),
      contentVersion: _versionWithLabel(contentVersion, jumpLabel),
      viewport: viewport,
      style: style,
      textColor: textColor,
      brightness: brightness,
      textDirection: textDirection,
      textScaler: textScaler,
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
    TextScaler textScaler = TextScaler.noScaling,
    Map<String, String> translations = const {},
    NovelTitleBlock? titleBlock,
    CancelToken? cancelToken,
    NovelLayoutBudget budget = const NovelLayoutBudget(),
    NovelLayoutProgressCallback? onProgress,
    NovelJumpLabel? jumpLabel,
  }) {
    return layoutCancellable(
      paragraphs: _paragraphsForDocument(document, jumpLabel),
      contentVersion: _versionWithLabel(contentVersion, jumpLabel),
      viewport: viewport,
      style: style,
      textColor: textColor,
      brightness: brightness,
      textDirection: textDirection,
      textScaler: textScaler,
      translations: translations,
      titleBlock: titleBlock,
      cancelToken: cancelToken,
      budget: budget,
      onProgress: onProgress,
    );
  }

  /// Where an author's link [mark] goes, or null for any other mark.
  static NovelLinkTarget? _linkTarget(NovelInlineMark mark) {
    final value = mark.value;
    if (value == null) return null;
    return switch (mark.kind) {
      'jump' || 'jumpuri' || 'jumpurl' => switch (int.tryParse(value)) {
        final page? => (page: page, uri: null),
        null => (page: null, uri: Uri.tryParse(value)),
      },
      _ => null,
    };
  }

  /// [paragraph] with [jumpLabel]'s label where a page jump has none of
  /// its own, its mark spanning the label so the line links it.
  static NovelParagraph _withJumpLabels(
    NovelParagraph paragraph,
    NovelJumpLabel? jumpLabel,
  ) {
    if (jumpLabel == null ||
        !paragraph.inlineMarks.any(
          (mark) => mark.kind == 'jump' && mark.start == mark.end,
        )) {
      return paragraph;
    }
    final text = StringBuffer();
    final marks = <NovelInlineMark>[];
    var copied = 0;
    var shift = 0;
    for (final mark in paragraph.inlineMarks) {
      final page = mark.kind == 'jump' && mark.start == mark.end
          ? int.tryParse(mark.value ?? '')
          : null;
      if (page == null) {
        marks.add(
          NovelInlineMark(
            kind: mark.kind,
            start: mark.start + shift,
            end: mark.end + shift,
            value: mark.value,
            raw: mark.raw,
          ),
        );
        continue;
      }
      final label = jumpLabel(page);
      text
        ..write(paragraph.text.substring(copied, mark.start))
        ..write(label);
      copied = mark.start;
      marks.add(
        NovelInlineMark(
          kind: mark.kind,
          start: mark.start + shift,
          end: mark.start + shift + label.length,
          value: mark.value,
          raw: mark.raw,
        ),
      );
      shift += label.length;
    }
    text.write(paragraph.text.substring(copied));
    return NovelParagraph(
      id: paragraph.id,
      text: text.toString(),
      inlineMarks: List.unmodifiable(marks),
      tokens: paragraph.tokens,
      pageBreakBefore: paragraph.pageBreakBefore,
      isChapterHeading: paragraph.isChapterHeading,
      image: paragraph.image,
    );
  }

  /// [contentVersion] with the jump label, which changes the laid-out text
  /// with the reader's language.
  static String _versionWithLabel(
    String contentVersion,
    NovelJumpLabel? jumpLabel,
  ) => jumpLabel == null
      ? contentVersion
      : '$contentVersion+jump:${jumpLabel(1)}';

  List<NovelParagraph> _paragraphsForDocument(
    NovelMarkupDocument document,
    NovelJumpLabel? jumpLabel,
  ) {
    final paragraphs = <NovelParagraph>[];
    var pendingPageBreak = false;
    for (final block in document.blocks) {
      switch (block) {
        case NovelParagraph():
          final paragraph = _withJumpLabels(block, jumpLabel);
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
        case NovelImageBlock():
          // A page of its own: the text after it starts the next one.
          paragraphs.add(
            NovelParagraph(
              id: block.id,
              text: '',
              pageBreakBefore: true,
              image: block.image,
            ),
          );
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

  /// The cache identity of a body laid out with [translations] under
  /// [titleBlock].
  static String _versionWith(
    String contentVersion,
    Map<String, String> translations,
    NovelTitleBlock? titleBlock,
  ) {
    var version = contentVersion;
    if (translations.isNotEmpty) {
      final digest = Object.hashAllUnordered([
        for (final entry in translations.entries)
          Object.hash(entry.key, entry.value),
      ]);
      version = '$version+${translations.length}:$digest';
    }
    if (titleBlock != null) version = '$version+title:${titleBlock.hashCode}';
    return version;
  }

  NovelLayoutKey _key({
    required String contentVersion,
    required Size viewport,
    required NovelLayoutStyle style,
    required Brightness brightness,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) {
    return NovelLayoutKey(
      contentVersion: contentVersion,
      viewport: viewport,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      fontSize: style.fontSize,
      lineHeight: style.lineHeight,
      fontWeight: style.fontWeight,
      brightness: brightness,
      textDirection: textDirection,
      textScaler: textScaler,
    );
  }

  Future<NovelLayout> _buildAsync({
    required List<NovelParagraph> paragraphs,
    required String contentVersion,
    required Map<String, String> translations,
    required NovelTitleBlock? titleBlock,
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
        textScaler: key.textScaler,
      );
      if (titleBlock != null) {
        lines.addAll(
          _cached(
            measure,
            titleBlock,
            () => _measureTitleBlock(titleBlock, paragraphs.first, measure),
          ),
        );
      }
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
        textScaler: key.textScaler,
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
    key.fontFamilyFallback == null
        ? null
        : Object.hashAll(key.fontFamilyFallback!),
    key.fontSize,
    key.lineHeight,
    key.fontWeight,
    key.textDirection,
    key.textScaler,
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
    if (paragraph.image case final image?) {
      // Its height is the page's, set when it is paginated.
      return [
        _MeasuredLine(
          paragraphIndex: paragraphIndex,
          paragraphId: paragraph.id,
          startOffset: 0,
          endOffset: 0,
          text: '',
          height: 0,
          isParagraphEnd: true,
          pageBreakBefore: true,
          kind: NovelLineKind.image,
          image: image,
        ),
      ];
    }
    final source = paragraph.text.isEmpty ? ' ' : paragraph.text;
    final kind = paragraph.isChapterHeading
        ? NovelLineKind.heading
        : NovelLineKind.body;
    final rows = _rows(
      source,
      style.lineStyle(kind, measure.textColor),
      measure,
    );
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
          kind: kind,
        ),
      ];
    }
    final length = paragraph.text.length;
    final links = [
      for (final mark in paragraph.inlineMarks)
        if (_linkTarget(mark) case final target? when mark.end > mark.start)
          (mark: mark, target: target),
    ];
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
            kind: kind,
            links: [
              for (final (:mark, :target) in links)
                if (mark.start < end && mark.end > start)
                  (
                    start: math.max(mark.start, start) - start,
                    end: math.min(mark.end, end) - start,
                    target: target,
                  ),
            ],
          );
        }(),
    ];
  }

  /// [block]'s lines, anchored at the start of [first], the first
  /// paragraph.
  List<_MeasuredLine> _measureTitleBlock(
    NovelTitleBlock block,
    NovelParagraph first,
    _Measure measure,
  ) {
    final lines = <_MeasuredLine>[];
    for (final (kind, text) in [
      (NovelLineKind.title, block.title),
      (NovelLineKind.byline, block.byline),
    ]) {
      if (text.isEmpty) continue;
      final rows = _rows(
        text,
        measure.style.lineStyle(kind, measure.textColor),
        measure,
      );
      for (final (index, row) in rows.indexed) {
        lines.add(
          _MeasuredLine(
            paragraphIndex: 0,
            paragraphId: first.id,
            startOffset: 0,
            endOffset: 0,
            text: text.substring(row.start, row.end),
            height: row.height,
            isParagraphEnd: index == rows.length - 1,
            kind: kind,
          ),
        );
      }
    }
    return lines;
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
      measure.style.lineStyle(NovelLineKind.translation, measure.textColor),
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
          kind: NovelLineKind.translation,
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
      textScaler: measure.textScaler,
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
            kind: line.kind,
            image: line.image,
            links: line.links,
          ),
      ];
      final first = current.first.line;
      final last = current.last.line;
      final firstText = current
          .firstWhere(
            (entry) => !entry.line.isTitleBlock,
            orElse: () => current.first,
          )
          .line;
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
          chapterTitle: firstText.chapterTitle,
          breakBefore: _breakBefore(first, paragraphs),
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
      if (line.image != null) {
        // The illustration fills a page of its own; the title block keeps
        // its first page.
        flush();
        current.add((line: line._withHeight(availableHeight), spacing: 0));
        flush();
        continue;
      }
      final spacing = _spacingAfter(line, next, style);
      final lineHeight = line.height + spacing;
      // The title block opens the first page with the text, even when the
      // text opens on a chapter.
      if (line.pageBreakBefore &&
          current.isNotEmpty &&
          !current.last.line.isTitleBlock) {
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

  /// A page break before a body paragraph is the author's `[newpage]`,
  /// unless an image made it: the text after an image starts a page too.
  static NovelPageBreak _breakBefore(
    _MeasuredLine first,
    List<NovelParagraph> paragraphs,
  ) {
    if (!first.pageBreakBefore) return NovelPageBreak.none;
    return switch (first.kind) {
      NovelLineKind.heading => NovelPageBreak.chapter,
      NovelLineKind.body
          when first.paragraphIndex == 0 ||
              paragraphs[first.paragraphIndex - 1].image == null =>
        NovelPageBreak.newPage,
      _ => NovelPageBreak.none,
    };
  }

  /// Paragraph spacing after a paragraph — after its translation when it
  /// has one, with the smaller translation gap between the two. A byline
  /// follows its title at the same gap; the text keeps its distance from
  /// the title block.
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
    final bylineFollows =
        line.kind == NovelLineKind.title && next?.kind == NovelLineKind.byline;
    if (line.isTitleBlock && !bylineFollows) return style.titleBlockGap;
    return translationFollows || bylineFollows
        ? style.translationGap
        : style.paragraphSpacing;
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
    this.kind = NovelLineKind.body,
    this.image,
    this.links = const [],
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
      kind = NovelLineKind.body,
      image = null,
      links = const [];

  final int paragraphIndex;
  final String paragraphId;
  final int startOffset;
  final int endOffset;
  final String text;
  final double height;
  final bool isParagraphEnd;
  final bool pageBreakBefore;
  final String? chapterTitle;
  final NovelLineKind kind;
  final NovelImageLoadRequest? image;
  final List<NovelLineLink> links;

  bool get isTranslation => kind == NovelLineKind.translation;

  bool get isTitleBlock =>
      kind == NovelLineKind.title || kind == NovelLineKind.byline;

  NovelAnchor get startAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: startOffset);

  NovelAnchor get endAnchor =>
      NovelAnchor(paragraphId: paragraphId, offset: endOffset);

  _MeasuredLine _withHeight(double height) => _MeasuredLine(
    paragraphIndex: paragraphIndex,
    paragraphId: paragraphId,
    startOffset: startOffset,
    endOffset: endOffset,
    text: text,
    height: height,
    isParagraphEnd: isParagraphEnd,
    pageBreakBefore: pageBreakBefore,
    chapterTitle: chapterTitle,
    kind: kind,
    image: image,
    links: links,
  );
}

/// One layout's measuring inputs.
class _Measure {
  const _Measure({
    required this.signature,
    required this.maxWidth,
    required this.style,
    required this.textColor,
    required this.textDirection,
    required this.textScaler,
  });

  /// Lines measured under an equal signature wrap the same way.
  final Object signature;
  final double maxWidth;
  final NovelLayoutStyle style;
  final Color textColor;
  final TextDirection textDirection;
  final TextScaler textScaler;
}
