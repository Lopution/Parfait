import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/widgets/feed/feed_grid.dart';

void main() {
  const ahead = 12;

  test('advancing builds warm the window after the built edge', () {
    final cursor = FeedPrefetchCursor();
    expect(cursor.advance(0, ahead: ahead), 1);
    expect(cursor.advance(1, ahead: ahead), 2);
    expect(cursor.advance(20, ahead: ahead), 21);
  });

  test('repeating the last built index schedules nothing', () {
    final cursor = FeedPrefetchCursor();
    cursor.advance(10, ahead: ahead);
    expect(cursor.advance(10, ahead: ahead), isNull);
  });

  test('a lower build warms the window above it (scroll-back)', () {
    final cursor = FeedPrefetchCursor();
    cursor.advance(100, ahead: ahead);
    expect(cursor.advance(80, ahead: ahead), 68);
    // Each new low continues the backward warm.
    expect(cursor.advance(70, ahead: ahead), 58);
  });

  test('re-advancing after a scroll-back warms forward again', () {
    final cursor = FeedPrefetchCursor();
    cursor.advance(100, ahead: ahead);
    cursor.advance(80, ahead: ahead);
    expect(cursor.advance(81, ahead: ahead), 82);
  });

  test('backward warm clamps at zero', () {
    final cursor = FeedPrefetchCursor();
    cursor.advance(30, ahead: ahead);
    expect(cursor.advance(5, ahead: ahead), 0);
  });
}
