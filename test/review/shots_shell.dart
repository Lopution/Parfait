import 'review_support.dart';

/// Onboarding and sign-in pages, seen signed out.
void main() {
  const signedOut = ReviewSetup(signedIn: false);
  const variants = {
    ShotVariant.dark,
    ...overflowVariants,
    ShotVariant.largeText,
    ShotVariant.talkBack,
  };

  testShot(
    'shell/welcome',
    location: '/welcome',
    setup: signedOut,
    variants: variants,
  );
  testShot(
    'shell/welcome-language',
    location: '/welcome/language',
    setup: signedOut,
  );
  testShot(
    'shell/user-agreement',
    location: '/user-agreement',
    setup: signedOut,
    variants: variants,
  );
  testShot(
    'shell/login',
    location: '/login',
    setup: signedOut,
    variants: variants,
  );
  // First run: the title is in the body, in front of the icon's glow.
  testShot(
    'shell/login-first',
    location: '/login?first=true',
    setup: signedOut,
  );
}
