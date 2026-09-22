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
  final lines = text.split('\n');
  if (readOffset >= text.length) {
    return (paragraphId: 'p${lines.length - 1}', offset: lines.last.length);
  }
  var base = 0;
  for (var i = 0; i < lines.length; i++) {
    final end = base + lines[i].length;
    if (readOffset <= end) {
      return (paragraphId: 'p$i', offset: readOffset - base);
    }
    base = end + 1; // step over the '\n' separator
  }
  return (paragraphId: 'p${lines.length - 1}', offset: lines.last.length);
}
