import 'review_support.dart';

/// The five home destinations, their in-page tabs and feed states.
void main() {
  testShot(
    'home/recommended',
    location: '/recommended',
    variants: {...ShotVariant.values},
  );
  testShot('home/recommended-manga', location: '/recommended?type=manga');
  testShot('home/recommended-novel', location: '/recommended?type=novel');
  testShot('home/ranking', location: '/ranking');
  testShot('home/ranking-week', location: '/ranking?mode=week');
  testShot('home/ranking-male', location: '/ranking?mode=dayMale');
  testShot('home/new', location: '/new');
  testShot('home/new-all', location: '/new?scope=all');
  testShot('home/new-mypixiv', location: '/new?scope=mypixiv');
  testShot(
    'home/search',
    location: '/search',
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
  );
  testShot(
    'home/settings',
    location: '/settings',
    variants: {...ShotVariant.values},
  );
  testShot(
    'home/recommended-semantics',
    location: '/recommended',
    variants: const {},
    semanticsDebugger: true,
  );

  testShot(
    'home/recommended-loading',
    location: '/recommended',
    state: 'loading',
    setup: ReviewSetup(api: {'/v1/illust/recommended': reviewLoading()}),
  );
  testShot(
    'home/recommended-empty',
    location: '/recommended',
    state: 'empty',
    setup: ReviewSetup(api: {'/v1/illust/recommended': reviewEmpty('illusts')}),
    variants: {ShotVariant.dark, ...overflowVariants},
  );
  testShot(
    'home/recommended-error',
    location: '/recommended',
    state: 'error',
    setup: ReviewSetup(api: {'/v1/illust/recommended': reviewError()}),
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.talkBack},
  );
  testShot(
    'home/ranking-empty',
    location: '/ranking',
    state: 'empty',
    setup: ReviewSetup(api: {'/v1/illust/ranking': reviewEmpty('illusts')}),
  );
  testShot(
    'home/new-error',
    location: '/new',
    state: 'error',
    setup: ReviewSetup(api: {'/v2/illust/follow': reviewError()}),
  );
}
