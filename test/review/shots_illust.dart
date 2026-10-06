import 'dart:async';

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
