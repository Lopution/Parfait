import 'review_support.dart';

/// Every settings subpage. Settings are the densest text in the app, so
/// each page runs in the overflow languages and at 1.3x text too.
void main() {
  const pages = {
    'account': '/settings/account',
    'theme': '/settings/theme',
    'language': '/settings/language',
    'translate': '/settings/translate',
    'translate-credentials': '/settings/translate/credentials/google',
    'network': '/settings/network',
    'network-probe': '/settings/network/probe',
    'network-advanced': '/settings/network/advanced',
    'frame-probe': '/settings/frame-probe',
    'browse': '/settings/browse',
    'motion': '/settings/motion',
    'download': '/settings/download',
    'download-destination': '/settings/download/destination',
    'muted': '/settings/muted',
    'backup': '/settings/backup',
    'tasks': '/settings/tasks',
    'about': '/settings/about',
    'about-licenses': '/settings/about/licenses',
  };
  for (final MapEntry(key: name, value: location) in pages.entries) {
    testShot(
      'settings/$name',
      location: location,
      variants: {ShotVariant.dark, ...overflowVariants, ShotVariant.largeText},
    );
  }
}
