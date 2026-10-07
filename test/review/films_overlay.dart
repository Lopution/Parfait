import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';

import 'review_support.dart';

/// Dialogs, sheets, menus and prompts opening and closing.
void main() {
  testFilm(
    'overlay/dialog',
    location: '/settings/account',
    notes:
        'The remove-account confirmation opening over the account page and '
        'closing on Cancel: the scrim fades with the dialog, focus returns.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.delete_outline));
      await film.tap(find.text('取消').last);
    },
  );

  testFilm(
    'overlay/filter-sheet',
    location: '/search/results?q=cat&type=illust',
    notes:
        'The search filter sheet rising and being dragged down to close; '
        'its top edge and the status bar area on every frame.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.tune));
      await film.swipe(find.text('筛选').last, const Offset(0, 900), count: 12);
    },
  );

  testFilm(
    'overlay/card-sheet',
    location: '/recommended',
    notes:
        'The card long-press sheet rising over the feed and dragged down to '
        'close. It names the work and lists download, watch later, mute '
        'and share, and no bookmark: the heart is on the card.',
    script: (film, router) async {
      await film.longPress(find.byType(PixivImage).at(1));
      await film.swipe(find.text('下载').last, const Offset(0, 900), count: 12);
    },
  );

  testFilm(
    'overlay/menu',
    location: '/recommended/illust/1000',
    notes:
        'The detail overflow menu opening from its button and closing on an '
        'outside tap that does not reach the page underneath.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.more_vert));
      await film.tap(find.text('illust 1000'));
    },
  );

  testFilm(
    'overlay/settings-menu',
    location: '/settings/browse',
    notes:
        'A settings choice row: its value sits at the row end; the menu '
        'opens below the row lined up with its end edge, under the value, '
        'the title left clear. Picking another option closes it and the '
        'value updates; reopened, an outside tap closes it.',
    script: (film, router) async {
      await film.tap(find.text('预览质量'));
      await film.tap(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('大图'),
        ),
      );
      await film.tap(find.text('预览质量'));
      await film.tap(find.text('浏览设置'));
    },
  );

  testFilm(
    'overlay/profile-menu',
    location: '/recommended/user/99',
    notes:
        'The profile overflow, expanded and collapsed. Expanded, share and '
        'follow sit in the name row and the menu leaves them out; once the '
        'header collapses the menu lists them too.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.more_vert));
      await film.tap(find.text('user 99'));
      await film.swipe(
        find.byKey(const ValueKey('profile-stat-following-header')),
        const Offset(0, -500),
        hold: 6,
      );
      await film.tap(find.byIcon(Icons.more_vert));
      await film.tap(find.text('user 99'));
    },
  );

  testFilm(
    'overlay/prompt-secondary',
    location: '/recommended/illust/1000',
    notes:
        'A prompt on a secondary page: "download all" queues the work and '
        'the confirmation enters, dwells and leaves on its own.',
    script: (film, router) async {
      await film.tap(find.byTooltip('下载全部'));
      await film.frames(240);
      await film.untilSettled();
    },
  );
}
