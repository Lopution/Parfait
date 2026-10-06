import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'review_support.dart';

/// Search input, results for the three targets, the filter sheet and the
/// reverse-image page.
void main() {
  const illusts = '/search/results?q=cat&type=illust';

  testShot(
    'search/input',
    location: '/search/input',
    variants: {ShotVariant.dark, ShotVariant.talkBack},
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
