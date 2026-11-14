import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';

import 'review_support.dart';

/// Multi-platform acceptance scenes covering all 5 OS shells (Android, iOS,
/// Windows, macOS, Linux), foldable postures (`book` and `tabletop`), adaptive
/// overlay container choices, and real isolate + chunked HTTP image streaming.
void main() {
  testShot('mp/home-recommended', location: '/recommended');

  testShot('mp/illust-detail', location: '/recommended/illust/1000');

  testShot(
    'mp/adaptive-dialog',
    location: '/recommended',
    before: (tester, router) async {
      await tester.longPress(find.byType(PixivImage).at(1));
    },
  );

  testShot(
    'mp/adaptive-sidesheet',
    location: '/search/results?q=landscape%20cat&type=illust',
    before: (tester, router) async {
      await tester.tap(find.byIcon(Icons.tune_outlined).first);
    },
  );

  testShot(
    'mp/progressive-detail',
    location: '/recommended/illust/1000',
    setup: const ReviewSetup(
      realWorkerIsolate: true,
      imageChunkSize: 16384,
      imageChunkDelay: Duration(milliseconds: 2),
    ),
  );
}
