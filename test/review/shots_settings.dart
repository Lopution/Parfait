import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';

import 'review_support.dart';

/// Every settings subpage. Settings are the densest text in the app, so
/// each page runs in the overflow languages and at 1.3x text too.
void main() {
  const pages = {
    'index': '/settings/all',
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
  // The Doubao engine adds its account row and the risk note.
  testShot(
    'settings/translate-doubao',
    location: '/settings/translate',
    variants: {ShotVariant.dark, ShotVariant.ru},
    before: (tester, router) async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .selectTranslationProvider(TranslationProvider.doubao),
      );
    },
  );
  // A query that matches a page, settings by title and one by an option.
  testShot(
    'settings/index-search',
    location: '/settings/all',
    variants: {ShotVariant.dark, ShotVariant.largeText},
    before: (tester, router) async {
      await tester.enterText(find.byType(SearchBar), '图');
    },
  );
}
