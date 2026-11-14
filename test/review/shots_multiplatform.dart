import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/settings/shared_preferences.dart';

import 'review_support.dart';

class _SpreadNovelSettingsStore extends NovelReaderSettingsStore {
  _SpreadNovelSettingsStore(super.preferences);

  NovelReaderSettings _current = const NovelReaderSettings(
    pageTurn: NovelPageTurn.pages,
    spreadMode: NovelSpreadMode.auto,
  );

  @override
  Future<NovelReaderSettings> load() async => _current;

  @override
  Future<void> save(NovelReaderSettings settings) async {
    _current = settings;
  }
}

/// Multi-platform acceptance scenes covering all 5 OS shells (Android, iOS,
/// Windows, macOS, Linux), foldable postures (`book` and `tabletop`), adaptive
/// overlay container choices, novel spreads, wide profiles/dashboards, and real
/// isolate + chunked HTTP image streaming.
void main() {
  testShot('mp/home-recommended', location: '/recommended');

  testShot(
    'mp/illust-detail',
    location: '/recommended',
    before: (tester, router) async {
      unawaited(router.push('/recommended/illust/1000'));
      await tester.pump();
    },
  );

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
    'mp/novel-spread',
    location: '/recommended/novel/2000',
    setup: ReviewSetup(
      overrides: [
        novelReaderSettingsStoreProvider.overrideWith(
          (ref) =>
              _SpreadNovelSettingsStore(ref.watch(sharedPreferencesProvider)),
        ),
      ],
    ),
  );

  testShot('mp/profile-user', location: '/recommended/user/99');

  testShot(
    'mp/me-dashboard',
    location: '/settings',
    before: (tester, router) async {
      final expandRail = find.byTooltip('展开侧栏');
      if (expandRail.evaluate().isNotEmpty) {
        await tester.tap(expandRail);
      }
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
