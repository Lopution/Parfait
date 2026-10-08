import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'review_support.dart';

/// Feed motion: pull to refresh, load more, the bottom bar following the
/// scroll, and tab switches.
void main() {
  testFilm(
    'feed/pull-to-refresh',
    location: '/recommended',
    notes:
        'A slow pull down from the top of the home feed and release: the '
        'refresh indicator follows the finger, spins while the feed '
        'reloads, then retracts; cards do not blank or jump.',
    script: (film, router) async {
      await film.swipe(
        find.text('illust 1000'),
        const Offset(0, 360),
        count: 24,
        hold: 4,
      );
    },
  );

  testFilm(
    'feed/load-more',
    location: '/recommended',
    notes:
        'Scrolling page by page to the end of the feed: the next page '
        'appends ahead of the viewport (prefetch), so the list never jumps '
        'or waits on a footer; at the end the tail shows the end marker. '
        'Images of the new cards fade in.',
    script: (film, router) async {
      // Slow drags of about a screen each, held before release: a fling
      // appended every page mid-flight in one blur.
      for (var i = 0; i < 5; i++) {
        await film.swipe(
          find.byType(CustomScrollView),
          const Offset(0, -900),
          count: 15,
          hold: 4,
        );
      }
    },
  );

  testFilm(
    'feed/bottom-bar-on-scroll',
    location: '/recommended',
    notes:
        'Scrolling the feed up hides the bottom bar, scrolling back down '
        'brings it back. The bar slides as a unit, its pill indicator stays '
        'on the selected destination, and nothing behind it flickers.',
    script: (film, router) async {
      await film.swipe(
        find.text('illust 1002'),
        const Offset(0, -600),
        count: 20,
        hold: 2,
      );
      await film.swipe(
        find.text('illust 1004'),
        const Offset(0, 300),
        count: 15,
        hold: 2,
      );
    },
  );

  for (final brightness in Brightness.values) {
    testFilm(
      brightness == Brightness.light
          ? 'feed/app-bar-edge'
          : 'feed/app-bar-edge-dark',
      location: '/recommended',
      brightness: brightness,
      notes:
          'Cards scroll up under the top bar, then back to the top. The bar '
          'keeps the page colour throughout; a thin line along its bottom '
          'edge fades in once content is under it and fades out at the top. '
          'No tint, no snap.',
      script: (film, router) async {
        await film.swipe(
          find.text('illust 1002'),
          const Offset(0, -240),
          count: 12,
          hold: 14,
        );
        await film.swipe(
          find.text('illust 1004'),
          const Offset(0, 400),
          count: 16,
          hold: 14,
        );
      },
    );
  }

  testFilm(
    'feed/tab-switch',
    location: '/recommended',
    notes:
        'Home top tabs: illustrations → manga → novels. The indicator '
        'slides, the pages swap without a blank frame, novel cards come in '
        'with their covers.',
    script: (film, router) async {
      await film.tap(find.text('漫画'));
      await film.tap(find.text('小说'));
    },
  );
}
