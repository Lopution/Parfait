import 'review_support.dart';

/// Novel reader, comments, novel ranking, new novels and local novels.
void main() {
  const novel = '/recommended/novel/2000';

  testShot('novel/reader', location: novel, variants: {...ShotVariant.values});
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
