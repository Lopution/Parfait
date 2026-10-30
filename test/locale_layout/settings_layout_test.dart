import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/translation/translation_service.dart'
    show translationCredentialStoreProvider;
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/i18n/replica_language.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/features/settings/network_probe_page.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/pages/translation_credentials_page.dart';
import 'package:parfait/features/settings/settings_page.dart';

import '../helpers/fake_account.dart';
import '../helpers/locale_layout.dart';
import '../helpers/settings_world.dart';

/// The settings pages, each in the language its own settings select.
/// The frame probe is a debug page and stays out.
final _pages = <String, Widget>{
  'me dashboard': const MeDashboardPage(),
  'settings': const SettingsPage(),
  'browse': const BrowseSettingsPage(),
  'motion': const MotionSettingsPage(),
  'navigation': const NavigationSettingsPage(),
  'bottom bar': const BottomBarSettingsPage(),
  'appearance': const ThemeSettingsPage(),
  'language': const LanguageSettingsPage(),
  'account': const AccountSettingsPage(),
  'backup': const BackupSettingsPage(),
  'download': const DownloadSettingsPage(),
  'download destination': const DownloadDestinationPage(),
  'muted items': const MutedItemsPage(),
  'translation': const TranslateSettingsPage(),
  'translation credentials (Baidu)': const TranslationCredentialsPage(
    baidu: true,
  ),
  'translation credentials (LLM)': const TranslationCredentialsPage(
    baidu: false,
  ),
  'about': const AboutSettingsPage(),
  'network': const NetworkSettingsPage(),
  'network (advanced)': const NetworkAdvancedSettingsPage(),
  'network probe': const NetworkProbePage(),
};

/// Signs in and stores [locale]'s settings, [adjust]ed.
Future<void> _seed(
  Locale locale, {
  AppSettings Function(AppSettings settings)? adjust,
}) async {
  await seedAccounts([
    const Account(id: '100', userId: 100, name: 'tester'),
  ], currentId: '100');
  await seedSettings(
    (adjust ?? (settings) => settings)(
      baseTestSettings(
        languageTag: ReplicaLanguage.fromTag(locale.languageCode).tag,
      ),
    ),
  );
}

final List<Override> _overrides = [
  translationCredentialStoreProvider.overrideWithValue(FakeTranslationStore()),
  networkAccessPolicyProvider.overrideWithValue(stubNetworkPolicy()),
  ...accountProviderOverrides(
    credentialStore: FakeCredentialStore(
      values: const {'100': Credential(accessToken: 'a', refreshToken: 'r')},
    ),
  ),
];

void main() {
  for (final MapEntry(key: name, value: page) in _pages.entries) {
    localeLayoutMatrix('settings: $name', (tester, locale, profile) async {
      await _seed(locale);
      await tester.pumpWidget(
        localeLayoutApp(locale: locale, overrides: _overrides, home: page),
      );
      await settleLayout(tester);
      await expectPageLayoutIntact(tester, locale: locale, profile: profile);
    });
  }

  // The custom template section with its variable chips.
  localeLayoutMatrix('settings: download (custom template)', (
    tester,
    locale,
    profile,
  ) async {
    await _seed(
      locale,
      adjust: (settings) => settings.copyWith(
        namingRule: const NamingRule(
          preset: NamingPreset.custom,
          template: '{id}_p{page}.{ext}',
        ),
      ),
    );
    await tester.pumpWidget(
      localeLayoutApp(
        locale: locale,
        overrides: _overrides,
        home: const DownloadSettingsPage(),
      ),
    );
    await settleLayout(tester);
    await expectPageLayoutIntact(tester, locale: locale, profile: profile);
  });
}
