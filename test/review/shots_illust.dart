import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
