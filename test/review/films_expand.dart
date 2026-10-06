import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/pixiv_image.dart';

import 'review_support.dart';

/// Expanding and collapsing: caption, multi-page works, download groups.
void main() {
  const detail = '/recommended/illust/1000';

  testFilm(
    'expand/caption',
    location: detail,
    notes:
        'The detail caption expanding past four lines and collapsing back. '
        'The text below moves with the caption height; the toggle label '
        'changes without the row jumping.',
    script: (film, router) async {
      await film.swipe(
        find.byType(PixivImage),
        const Offset(0, -500),
        count: 15,
        hold: 4,
      );
      await film.tap(find.text('展开'));
      await film.tap(find.text('收起'));
    },
  );

  testFilm(
    'expand/pages',
    location: detail,
    notes:
        'A three-page work: "expand all" grows the pager into the page '
        'list; the button leaves and the pages that arrive load in place.',
    script: (film, router) async {
      await film.tap(find.textContaining('展开全部'));
      await film.frames(10);
    },
  );

  testFilm(
    'expand/download-group',
    location: '/downloads',
    setup: const ReviewSetup(downloadGroups: 1, downloadSingles: 2),
    notes:
        'A download group expanding to its three items and collapsing '
        'again. The group outline keeps round corners on every frame — the '
        'header bottom while the items leave included (ux3 #8).',
    script: (film, router) async {
      await film.tap(find.textContaining('批量下载'));
      await film.tap(find.textContaining('批量下载'));
    },
  );
}
