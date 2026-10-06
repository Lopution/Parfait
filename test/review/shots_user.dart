import 'review_support.dart';

/// Artist profile, profile edit and the /me page.
void main() {
  const user = '/recommended/user/99';

  testShot('user/profile', location: user, variants: {...ShotVariant.values});
  testShot('user/profile-edit', location: '/recommended/profile/99/edit');
  testShot(
    'user/me',
    location: '/me',
    variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
  );

  testShot(
    'user/profile-loading',
    location: user,
    state: 'loading',
    setup: ReviewSetup(api: {'/v1/user/detail': reviewLoading()}),
  );
  testShot(
    'user/profile-error',
    location: user,
    state: 'error',
    setup: ReviewSetup(api: {'/v1/user/detail': reviewError()}),
  );
  testShot(
    'user/profile-no-works',
    location: user,
    state: 'empty',
    setup: ReviewSetup(
      api: {
        '/v1/user/illusts': reviewEmpty('illusts'),
        '/v1/user/novels': reviewEmpty('novels'),
      },
    ),
  );
}
