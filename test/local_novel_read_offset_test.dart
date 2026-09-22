import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/localnovel/read_offset_anchor.dart';

/// The forward direction: mirrors `_persistCursor` in
/// local_novel_reader_page.dart — a paragraph anchor is a character offset
/// into the `\n`-joined text.
int forwardOffset(String text, String paragraphId, int offset) {
  final lines = text.split('\n');
  var base = 0;
  for (var i = 0; i < lines.length; i++) {
    if ('p$i' == paragraphId) return base + offset;
    base += lines[i].length + 1;
  }
  throw ArgumentError('unknown paragraph $paragraphId');
}

void main() {
  test('empty or absent cursors restore nothing', () {
    expect(novelAnchorForReadOffset(null, 'a\nb'), isNull);
    expect(novelAnchorForReadOffset(0, 'a\nb'), isNull);
    expect(novelAnchorForReadOffset(-3, 'a\nb'), isNull);
    expect(novelAnchorForReadOffset(4, ''), isNull);
  });

  test('offsets inside a paragraph map to that paragraph', () {
    const text = 'hello\nworld';
    expect(novelAnchorForReadOffset(1, text), (paragraphId: 'p0', offset: 1));
    expect(novelAnchorForReadOffset(8, text), (paragraphId: 'p1', offset: 2));
  });

  test('a newline position belongs to the paragraph before it', () {
    // 'hello\nworld': the '\n' sits at offset 5 — the persist side produces
    // it as p0's end anchor, never as p1's start (that is offset 6).
    const text = 'hello\nworld';
    expect(novelAnchorForReadOffset(5, text), (paragraphId: 'p0', offset: 5));
    expect(novelAnchorForReadOffset(6, text), (paragraphId: 'p1', offset: 0));
  });

  test('round-trips every anchor the persist side can produce', () {
    const text = 'ab\n\ncd\nef';
    for (var i = 0; i < text.split('\n').length; i++) {
      final length = text.split('\n')[i].length;
      for (var offset = 0; offset <= length; offset++) {
        final stored = forwardOffset(text, 'p$i', offset);
        // Offset 0 is the document start — "nothing to restore" is the
        // same landing page, so the function reports null there.
        expect(
          novelAnchorForReadOffset(stored, text),
          stored == 0 ? null : (paragraphId: 'p$i', offset: offset),
          reason: 'p$i:$offset -> $stored',
        );
      }
    }
  });

  test('an offset past the end clamps to the last paragraph', () {
    const text = 'a\nb';
    expect(novelAnchorForReadOffset(3, text), (paragraphId: 'p1', offset: 1));
    expect(novelAnchorForReadOffset(999, text), (paragraphId: 'p1', offset: 1));
  });

  test('a trailing newline keeps the final empty paragraph reachable', () {
    const text = 'a\n';
    expect(novelAnchorForReadOffset(1, text), (paragraphId: 'p0', offset: 1));
    // Offset 2 is past the last character; the empty tail clamps.
    expect(novelAnchorForReadOffset(2, text), (paragraphId: 'p1', offset: 0));
  });
}
