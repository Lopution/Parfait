import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/translation/translation_service.dart';

import 'review_support.dart';

/// Novel reader, comments, novel ranking, new novels and local novels.
void main() {
  const novel = '/recommended/novel/2000';

  testShot('novel/reader', location: novel, variants: {...ShotVariant.values});
  // Bilingual reading on: the chrome with the selected translate button,
  // then the page itself once the chrome is gone.
  final bilingual = ReviewSetup(
    overrides: [translationServiceProvider.overrideWithValue(_ReviewEngine())],
  );
  Future<void> translatePage(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.translate));
  }

  testShot(
    'novel/reader-bilingual-chrome',
    location: novel,
    setup: bilingual,
    variants: const {},
    before: (tester, router) => translatePage(tester),
  );
  testShot(
    'novel/reader-bilingual',
    location: novel,
    setup: bilingual,
    before: (tester, router) async {
      await translatePage(tester);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byType(PageView)));
    },
  );
  testShot('novel/comments', location: '$novel/comments');
  testShot('novel/ranking', location: '/recommended/novel-ranking');
  testShot(
    'novel/ranking-male',
    location: '/recommended/novel-ranking?mode=day_male',
  );
  testShot('novel/new', location: '/recommended/new-novels');
  testShot('novel/new-all', location: '/recommended/new-novels?scope=all');
  testShot(
    'local-novels/list',
    location: '/recommended/local-novels',
    setup: const ReviewSetup(localNovels: 3),
  );
  testShot(
    'local-novels/reader',
    location: '/recommended/local-novels/1',
    setup: const ReviewSetup(localNovels: 3),
  );

  testShot(
    'novel/reader-loading',
    location: novel,
    state: 'loading',
    setup: ReviewSetup(api: {'/v2/novel/detail': reviewLoading()}),
  );
  testShot(
    'novel/reader-error',
    location: novel,
    state: 'error',
    setup: ReviewSetup(api: {'/v2/novel/detail': reviewError()}),
    variants: {ShotVariant.dark, ...overflowVariants},
  );
  testShot(
    'novel/ranking-empty',
    location: '/recommended/novel-ranking',
    state: 'empty',
    setup: ReviewSetup(api: {'/v1/novel/ranking': reviewEmpty('novels')}),
  );
  testShot(
    'local-novels/empty',
    location: '/recommended/local-novels',
    state: 'empty',
  );
}

/// A stand-in engine whose translations read like Chinese prose.
class _ReviewEngine
    with SequentialBatchTranslation
    implements TranslationTransport {
  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async => '这是一段译文，用来检查双语排版的字号、颜色和段落间距是否合适。';
}
