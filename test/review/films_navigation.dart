import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/pixiv_image.dart';

import 'review_support.dart';

/// Route pushes and pops, branch switches and re-tap to top.
void main() {
  final back = find.byTooltip('返回');

  testFilm(
    'nav/page-push-pop',
    // The full settings list; `/settings` itself is the "me" dashboard.
    location: '/settings/all',
    notes:
        'A plain page: the theme settings slide in over the settings hub and '
        'slide back out. The entering page stays live — its switches are '
        'drawn, not a frozen snapshot — and the hub reappears without a '
        'stale press highlight on the tile that was tapped.',
    script: (film, router) async {
      await film.tap(find.text('主题'), hold: 6);
      await film.tap(back.last);
    },
  );

  testFilm(
    'nav/hero-detail',
    location: '/recommended',
    notes:
        'Hero into the detail page from a feed card and back. The finger '
        'rests 250ms, past the press delay, so the card is scaled down when '
        'it lifts: the card springs back under the transition, not frozen '
        'pressed in it (ux3 #7). The detail page covers the bottom bar, '
        'which leaves and returns with the feed. The image flies from the '
        'card to the '
        'pager; detail content (title, author, follow button) is live while '
        'it arrives; on the way back the card takes the image without a '
        'gap, a square-cornered frame or a late pop to full size.',
    script: (film, router) async {
      await film.tap(find.byType(PixivImage), hold: 15);
      await film.frames(20);
      await film.tap(back.last);
    },
  );

  testFilm(
    'nav/viewer-open-close',
    location: '/recommended/illust/1000',
    notes:
        'The viewer opening from the detail image and closing with the back '
        'button: the black backdrop fades, the image keeps its place, the '
        'system bars hide and return.',
    script: (film, router) async {
      await film.tap(find.byType(PixivImage));
      await film.frames(10);
      await film.tap(back.last);
    },
  );

  testFilm(
    'nav/branch-switch',
    location: '/recommended',
    notes:
        'Bottom bar: home → ranking → home. The branches slide side by '
        'side toward the chosen destination under a still bar; the entering '
        'branch is live, the leaving one slides as one texture; the '
        'indicator pill moves with the selection.',
    script: (film, router) async {
      await film.tap(find.text('排行'));
      await film.tap(find.text('推荐'));
    },
  );

  testFilm(
    'nav/retap-to-top',
    location: '/recommended',
    notes:
        'Scrolled down the home feed, tapping the selected home destination '
        'again scrolls back to the top.',
    script: (film, router) async {
      await film.swipe(find.text('illust 1004'), const Offset(0, -1400));
      // Scrolling down hid the bottom bar; a short scroll back up returns
      // it before the tap, as a thumb would.
      await film.swipe(
        find.byType(PixivImage).hitTestable().first,
        const Offset(0, 300),
        count: 15,
        hold: 2,
      );
      await film.tap(find.text('推荐'));
    },
  );
}
