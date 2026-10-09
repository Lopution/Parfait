import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/tag_chips.dart';

import 'review_support.dart';

/// Illust detail, viewer, comments and replies — the deep pages off feeds.
void main() {
  const detail = '/recommended/illust/1000';
  const comments = '$detail/comments';
  // Not in the recommended feed underneath, whose cached entity would
  // stand in for a failed detail load.
  const uncached = '/recommended/illust/9000';

  testShot(
    'illust/detail',
    location: detail,
    variants: {...ShotVariant.values},
  );
  // Past the first image: the top bar has drawn its surface and title; a
  // short scroll back up has brought the action bar back.
  testShot(
    'illust/detail-scrolled',
    location: detail,
    before: (tester, router) async {
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(900);
      await tester.pump();
      position.jumpTo(860);
    },
  );
  // The info blocks: date, stats, author, titled caption and tags.
  testShot(
    'illust/detail-info',
    location: detail,
    variants: {ShotVariant.dark, ShotVariant.ru},
    before: (tester, router) async {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(240);
    },
  );
  // The caption's translate button pressed while translation is off: the
  // failure row points to the settings.
  testShot(
    'illust/detail-translate',
    location: detail,
    before: (tester, router) async {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(240);
      // The detail page keeps animating images; pump instead of settle.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byIcon(Icons.translate).first);
    },
  );
  // The tag menu after a long press, with its translate row asked.
  testShot(
    'illust/detail-tag-menu',
    location: detail,
    before: (tester, router) async {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(400);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.longPress(find.byType(TagChip).first);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byIcon(Icons.translate).last);
    },
  );
  // Below the info: the comment preview and the author's other works.
  testShot(
    'illust/detail-more',
    location: detail,
    before: (tester, router) async {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(900);
    },
  );
  // Further down: the author's works over related works, on one inset.
  testShot(
    'illust/detail-related',
    location: detail,
    variants: {ShotVariant.dark},
    before: (tester, router) async {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(1250);
    },
  );
  // An expanded set read into page 2: the fold pill hangs under the count.
  testShot(
    'illust/detail-expanded',
    location: detail,
    before: (tester, router) async {
      await tester.tap(find.byKey(const Key('illust-expand-pages')));
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(330);
    },
  );
  // The viewer reads the work the detail page loaded; a cold deep link has
  // no pages to show.
  testShot(
    'illust/viewer',
    location: detail,
    variants: {ShotVariant.talkBack},
    before: (tester, router) async {
      unawaited(router.push<void>('$detail/viewer/0'));
    },
  );
  testShot('illust/comments', location: comments);
  testShot('illust/replies', location: '$comments/1');

  testShot(
    'illust/detail-loading',
    location: uncached,
    state: 'loading',
    setup: ReviewSetup(api: {'/v1/illust/detail': reviewLoading()}),
  );
  testShot(
    'illust/detail-error',
    location: uncached,
    state: 'error',
    setup: ReviewSetup(api: {'/v1/illust/detail': reviewError()}),
    variants: {ShotVariant.dark, ...overflowVariants},
  );
  testShot(
    'illust/detail-not-found',
    location: uncached,
    state: 'not found',
    setup: ReviewSetup(api: {'/v1/illust/detail': reviewError(404)}),
  );
  testShot(
    'illust/comments-empty',
    location: comments,
    state: 'empty',
    setup: ReviewSetup(api: {'/v3/illust/comments': reviewEmpty('comments')}),
  );
  testShot(
    'illust/comments-error',
    location: comments,
    state: 'error',
    setup: ReviewSetup(api: {'/v3/illust/comments': reviewError()}),
  );
}
