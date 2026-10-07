import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/search/search_autocomplete_controller.dart';

import 'review_support.dart';

/// Search input, results for the three targets, the filter sheet and the
/// reverse-image page.
void main() {
  const illusts = '/search/results?q=cat&type=illust';

  const history = ReviewSetup(
    searchHistory: ['初音ミク', 'landscape', '猫', 'オリジナル', 'scenery'],
  );
  testShot(
    'search/input',
    location: '/search/input',
    setup: history,
    variants: {ShotVariant.dark, ShotVariant.talkBack, ...overflowVariants},
  );
  testShot(
    'search/input-suggestions',
    location: '/search/input',
    state: 'typed keyword',
    before: (tester, router) async {
      await tester.enterText(find.byType(TextField).last, 'cat');
      // Past the debounce, so the settle's IO turns deliver the request.
      await tester.pump(SearchAutocompleteController.debounceDuration);
    },
  );
  testShot(
    'search/input-id',
    location: '/search/input',
    state: 'typed id',
    before: (tester, router) async {
      await tester.enterText(find.byType(TextField).last, '12345678');
    },
  );
  testShot(
    'search/results-illust',
    location: illusts,
    variants: {...ShotVariant.values},
  );
  testShot(
    'search/results-novel',
    location: '/search/results?q=cat&type=novel',
  );
  testShot('search/results-user', location: '/search/results?q=cat&type=user');
  testShot(
    'search/filter-sheet',
    location: illusts,
    state: 'filter sheet',
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
    before: (tester, router) async {
      await tester.tap(find.byIcon(Icons.tune).first);
    },
  );
  testShot('reverse-image/page', location: '/reverse-image');

  testShot(
    'search/results-loading',
    location: illusts,
    state: 'loading',
    setup: ReviewSetup(api: {'/v1/search/illust': reviewLoading()}),
  );
  testShot(
    'search/results-empty',
    location: illusts,
    state: 'empty',
    setup: ReviewSetup(api: {'/v1/search/illust': reviewEmpty('illusts')}),
    variants: {ShotVariant.dark, ...overflowVariants},
  );
  testShot(
    'search/results-error',
    location: illusts,
    state: 'error',
    setup: ReviewSetup(api: {'/v1/search/illust': reviewError()}),
  );
}
