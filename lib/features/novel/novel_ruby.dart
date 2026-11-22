import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/novel/novel_entity.dart';

/// A ruby (furigana) annotation on a line or paragraph slice: its range in
/// the owning text and the reading painted above the base characters.
typedef NovelLineRuby = ({int start, int end, String reading});

/// Pre-measured geometry of a single stacked furigana box, shared between
/// layout (`NovelLayoutEngine`) and rendering (`NovelParagraphSliceView`).
typedef NovelRubyBox = ({
  double width,
  double rubyHeight,
  double baseHeight,
  double totalHeight,
  double baseline,
});

/// Relative size of furigana glyphs compared to the base line font size.
const novelRubyFontScale = 0.5;

/// Minimum furigana font size so ruby stays legible on compact font settings.
const novelRubyMinFontSize = 8.0;

/// Style used for stacked furigana readings above [baseStyle].
TextStyle novelRubyTextStyle(TextStyle baseStyle) => baseStyle.copyWith(
  fontSize: math.max(
    novelRubyMinFontSize,
    (baseStyle.fontSize ?? 17.0) * novelRubyFontScale,
  ),
  height: 1.15,
  fontWeight: FontWeight.w400,
);

/// Extracts valid, non-overlapping `rb` marks from [paragraph] in source order.
List<NovelLineRuby> extractNovelRubies(NovelParagraph paragraph) {
  final length = paragraph.text.length;
  if (length == 0 || paragraph.inlineMarks.isEmpty) return const [];
  final result = <NovelLineRuby>[];
  var cursor = 0;
  for (final mark in paragraph.inlineMarks) {
    if (mark.kind != 'rb') continue;
    final reading = mark.value?.trim();
    if (reading == null || reading.isEmpty) continue;
    final start = mark.start.clamp(0, length);
    final end = mark.end.clamp(start, length);
    if (end <= start || start < cursor) continue;
    result.add((start: start, end: end, reading: reading));
    cursor = end;
  }
  return result;
}

/// Measures a stacked furigana box so layout and rendering agree on width,
/// total height, and alphabetic baseline alignment with adjacent body glyphs.
NovelRubyBox measureNovelRubyBox({
  required String base,
  required String reading,
  required TextStyle baseStyle,
  required TextStyle rubyStyle,
  required TextDirection textDirection,
  required TextScaler textScaler,
}) {
  final basePainter = TextPainter(
    text: TextSpan(text: base, style: baseStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final rubyPainter = TextPainter(
    text: TextSpan(text: reading, style: rubyStyle),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final baseWidth = basePainter.width;
  final baseHeight = basePainter.height;
  final baseBaseline = basePainter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  final rubyWidth = rubyPainter.width;
  final rubyHeight = rubyPainter.height;
  basePainter.dispose();
  rubyPainter.dispose();
  return (
    width: math.max(baseWidth, rubyWidth),
    rubyHeight: rubyHeight,
    baseHeight: baseHeight,
    totalHeight: rubyHeight + baseHeight,
    baseline: rubyHeight + baseBaseline,
  );
}

/// Measures a paragraph containing [rubies] with atomic furigana boxes,
/// mapping each laid-out visual line back to UTF-16 ranges of [text].
///
/// Any ruby box wider than [maxWidth] falls back to plain wrapping so an
/// abnormally long annotation never overflows the text column.
({
  List<({int start, int end, double height})> rows,
  List<NovelLineRuby> activeRubies,
})
measureRubyParagraphRows({
  required String text,
  required List<NovelLineRuby> rubies,
  required TextStyle style,
  required double maxWidth,
  required TextDirection textDirection,
  required TextScaler textScaler,
}) {
  final rubyStyle = novelRubyTextStyle(style);
  final spans = <InlineSpan>[];
  final dims = <PlaceholderDimensions>[];
  final spanToOrig = <int>[];
  final activeRubies = <NovelLineRuby>[];

  void appendPlain(int from, int to) {
    if (to <= from) return;
    spans.add(TextSpan(text: text.substring(from, to)));
    for (var i = from; i < to; i++) {
      spanToOrig.add(i);
    }
  }

  var at = 0;
  for (final ruby in rubies) {
    appendPlain(at, ruby.start);
    final base = text.substring(ruby.start, ruby.end);
    final box = measureNovelRubyBox(
      base: base,
      reading: ruby.reading,
      baseStyle: style,
      rubyStyle: rubyStyle,
      textDirection: textDirection,
      textScaler: textScaler,
    );
    if (box.width > maxWidth) {
      appendPlain(ruby.start, ruby.end);
    } else {
      activeRubies.add(ruby);
      spans.add(
        const WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: SizedBox.shrink(),
        ),
      );
      dims.add(
        PlaceholderDimensions(
          size: Size(box.width, box.totalHeight),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: box.baseline,
        ),
      );
      spanToOrig.add(ruby.start);
    }
    at = ruby.end;
  }
  appendPlain(at, text.length);
  spanToOrig.add(text.length);

  final painter =
      TextPainter(
          text: TextSpan(style: style, children: spans),
          textDirection: textDirection,
          textScaler: textScaler,
        )
        ..setPlaceholderDimensions(dims)
        ..layout(maxWidth: maxWidth);

  final spanLen = spanToOrig.length - 1;
  final rows = [
    for (final metric in painter.computeLineMetrics())
      () {
        final lineTop = metric.baseline - metric.ascent;
        final pos = painter.getPositionForOffset(Offset(0, lineTop + 0.5));
        final range = painter.getLineBoundary(pos);
        final start = spanToOrig[range.start.clamp(0, spanLen)];
        final end = spanToOrig[range.end.clamp(0, spanLen)];
        return (start: start, end: math.max(start, end), height: metric.height);
      }(),
  ];
  painter.dispose();
  return (rows: rows, activeRubies: activeRubies);
}

/// Measures [paragraph]'s lines using atomic ruby boxes when it carries valid
/// `rb` marks, or delegates to [measurePlain] on the zero-overhead fast path.
({
  List<({int start, int end, double height})> rows,
  List<NovelLineRuby> activeRubies,
})
measureNovelParagraphRows({
  required NovelParagraph paragraph,
  required String text,
  required TextStyle style,
  required double maxWidth,
  required TextDirection textDirection,
  required TextScaler textScaler,
  required List<({int start, int end, double height})> Function() measurePlain,
}) {
  final rawRubies = extractNovelRubies(paragraph);
  if (rawRubies.isEmpty) {
    return (rows: measurePlain(), activeRubies: const []);
  }
  return measureRubyParagraphRows(
    text: text,
    rubies: rawRubies,
    style: style,
    maxWidth: maxWidth,
    textDirection: textDirection,
    textScaler: textScaler,
  );
}

/// Slices paragraph-level [rubies] to a visual line's `[start, end)` range.
List<NovelLineRuby> sliceNovelRubies(
  List<NovelLineRuby> rubies,
  int start,
  int end,
) {
  if (rubies.isEmpty) return const [];
  return [
    for (final r in rubies)
      if (r.start >= start && r.end <= end)
        (start: r.start - start, end: r.end - start, reading: r.reading),
  ];
}
