/// Inverse of the local reader's cursor persistence. `read_offset` is a
/// character offset into the `\n`-joined document while the reader consumes
/// paragraph-scoped anchors (`paragraphId` + intra-paragraph offset).
///
/// The persist side only produces anchors inside a paragraph's own range,
/// so the separator position itself is attributed to the paragraph before
/// it (its end-of-paragraph anchor) — read → write → read stays a stable
/// round trip. A cursor past the end of a shortened document clamps to the
/// last paragraph's end, which resolves to the final page; the reader then
/// writes the clamped position back and the library self-heals.
library;

import 'dart:typed_data';

/// Builds the compact UTF-16 start offset table for every `\n`-delimited line
/// in [text] in a single linear pass without allocating per-line substrings.
Int32List buildLocalNovelLineStarts(String text) {
  var lines = 1;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) lines += 1;
  }
  final starts = Int32List(lines);
  var line = 1;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      starts[line++] = i + 1;
    }
  }
  return starts;
}

/// Maps a stored `read_offset` onto a paragraph anchor in O(log N) using a
/// precomputed [lineStarts] table from [buildLocalNovelLineStarts].
({String paragraphId, int offset})? novelAnchorForReadOffsetWithStarts(
  int? readOffset,
  Int32List lineStarts,
  int textLength,
) {
  if (readOffset == null ||
      readOffset <= 0 ||
      textLength <= 0 ||
      lineStarts.isEmpty) {
    return null;
  }
  final lastIndex = lineStarts.length - 1;
  if (readOffset >= textLength) {
    return (
      paragraphId: 'p$lastIndex',
      offset: textLength - lineStarts[lastIndex],
    );
  }
  var lo = 0;
  var hi = lastIndex;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (lineStarts[mid] <= readOffset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return (paragraphId: 'p$lo', offset: readOffset - lineStarts[lo]);
}

/// Maps a paragraph-scoped anchor (`p<index>` + intra-paragraph [offset]) back
/// to a document UTF-16 offset in O(1) using [lineStarts].
int localNovelReadOffsetForAnchor({
  required String paragraphId,
  required int offset,
  required Int32List lineStarts,
  required int textLength,
}) {
  if (lineStarts.isEmpty || textLength <= 0) return 0;
  if (paragraphId.length > 1 && paragraphId.codeUnitAt(0) == 0x70 /* 'p' */ ) {
    final index = int.tryParse(paragraphId.substring(1));
    if (index != null && index >= 0 && index < lineStarts.length) {
      final raw = lineStarts[index] + offset;
      return raw.clamp(0, textLength);
    }
  }
  return offset.clamp(0, textLength);
}

/// Maps a stored `read_offset` onto the anchor the reader should restore.
///
/// Returns `null` when there is nothing meaningful to restore: no cursor,
/// a cursor at the very start, or an empty document — all of which open on
/// the first page.
({String paragraphId, int offset})? novelAnchorForReadOffset(
  int? readOffset,
  String text,
) {
  if (readOffset == null || readOffset <= 0 || text.isEmpty) return null;
  var lineIndex = 0;
  var lineStart = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) != 0x0A) continue;
    if (readOffset <= i) {
      return (paragraphId: 'p$lineIndex', offset: readOffset - lineStart);
    }
    lineIndex += 1;
    lineStart = i + 1;
  }
  final clamped = readOffset > text.length ? text.length : readOffset;
  return (paragraphId: 'p$lineIndex', offset: clamped - lineStart);
}
