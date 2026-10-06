import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
