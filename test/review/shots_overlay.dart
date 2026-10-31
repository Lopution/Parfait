import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';

import 'review_support.dart';

/// The layers above a page at rest, for their lift (THEME-20): a dialog, a
/// modal sheet, end-edge menus and a prompt. films_overlay.dart has them
/// opening and closing.
void main() {
  testShot(
    'overlay/dialog',
    location: '/settings/account',
    before: (tester, router) async {
      await tester.tap(find.byIcon(Icons.delete_outline));
    },
  );
  testShot(
    'overlay/card-sheet',
    location: '/recommended',
    before: (tester, router) async {
      await tester.longPress(find.byType(PixivImage).at(1));
    },
  );
  // A ⋮ at the screen edge: the menu keeps off the edge (FB-01).
  testShot(
    'overlay/menu',
    location: '/recommended/illust/1000',
    before: (tester, router) async {
      await tester.tap(find.byIcon(Icons.more_vert));
    },
  );
  testShot(
    'overlay/settings-menu',
    location: '/settings/browse',
    before: (tester, router) async {
      await tester.tap(find.text('预览质量'));
    },
  );
  testShot(
    'overlay/prompt',
    location: '/recommended/illust/1000',
    before: (tester, router) async {
      await tester.tap(find.byIcon(Icons.download_outlined));
    },
  );
}
