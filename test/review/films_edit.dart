import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';

import 'review_support.dart';

/// Inserting and deleting with prompts: bookmark undo on a branch home and
/// on a secondary page, removing a download, unmuting.
void main() {
  testFilm(
    'edit/unbookmark-undo-home',
    location: '/recommended',
    notes:
        'Long-press a bookmarked card, choose "remove bookmark" in the '
        'sheet: the sheet closes, the heart empties, the prompt with Undo '
        'slides in above the bottom bar; Undo fills the heart again and the '
        'prompt leaves.',
    script: (film, router) async {
      await film.longPress(find.byType(PixivImage).at(1));
      await film.tap(find.text('取消收藏'));
      await film.frames(20);
      await film.tap(find.text('撤销'));
    },
  );

  testFilm(
    'edit/bookmark-toggle-detail',
    location: '/recommended/illust/1000',
    notes:
        'The detail heart: bookmark (the heart pops), then remove it — the '
        'prompt with Undo enters on a secondary page, above the content and '
        'clear of the system navigation bar.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.favorite_outline_sharp));
      await film.tap(find.byIcon(Icons.favorite_sharp));
      await film.frames(30);
    },
  );

  testFilm(
    'edit/download-remove',
    location: '/downloads',
    setup: const ReviewSetup(downloadSingles: 3),
    notes:
        'Removing a finished download from its menu: the menu opens from '
        'the button and closes, the row collapses and the rows below move '
        'up with round corners kept.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.more_vert));
      await film.tap(find.text('移除').last);
    },
  );

  testFilm(
    'edit/download-group-remove',
    location: '/downloads',
    setup: const ReviewSetup(downloadGroups: 1),
    notes:
        'Removing the last item of an expanded download group: the group '
        'surface shrinks with the leaving row, its bottom corners round on '
        'every frame (ux3 #8).',
    script: (film, router) async {
      await film.tap(find.textContaining('批量下载'));
      await film.tap(find.byIcon(Icons.more_vert).last);
      await film.tap(find.text('移除').last);
    },
  );

  testFilm(
    'edit/account-remove',
    location: '/settings/account',
    setup: const ReviewSetup(accounts: 2),
    notes:
        'Removing the second of two accounts: the confirm dialog closes, '
        'the row collapses from its bottom edge, and as it starts the first '
        'row\'s bottom corners round and the gap between them closes — no '
        'square corner and no 2dp step when the row is gone.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.delete_outline).last);
      await film.tap(find.text('确定'));
      await film.frames(10);
    },
  );

  testFilm(
    'edit/unmute-undo',
    location: '/settings/muted',
    notes:
        'Unmuting a tag: the row leaves, the prompt with Undo enters; Undo '
        'puts the row back in place.',
    script: (film, router) async {
      await film.tap(find.byIcon(Icons.visibility_outlined));
      await film.frames(20);
      await film.tap(find.text('撤销'));
    },
  );
}
