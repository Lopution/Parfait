import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/comments/comment_translation.dart'
    show translationCredentialStoreProvider;
import 'package:parfait/core/i18n/replica_language.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/network_probe_page.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/pages/translation_credentials_page.dart';
import 'package:parfait/features/settings/settings_page.dart';

import '../helpers/fake_account.dart';
import '../helpers/locale_layout.dart';
import '../helpers/settings_world.dart';
import '../helpers/test_preferences.dart';

/// The settings pages, each in the language its own settings select.
/// The frame probe is a debug page and stays out.
final _pages = <String, Widget>{
  'settings': const SettingsPage(),
  'browse': const BrowseSettingsPage(),
  'appearance': const ThemeSettingsPage(),
  'language': const LanguageSettingsPage(),
  'account': const AccountSettingsPage(),
  'backup': const BackupSettingsPage(),
  'download': const DownloadSettingsPage(),
  'download destination': const DownloadDestinationPage(),
  'history': const HistorySettingsPage(),
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

List<Override> _overrides(Locale locale) => [
  settingsRepositoryProvider.overrideWithValue(
    FakeSettingsRepository(
      baseTestSettings(
        languageTag: ReplicaLanguage.fromTag(locale.languageCode).tag,
      ),
    ),
  ),
  translationCredentialStoreProvider.overrideWithValue(FakeTranslationStore()),
  networkAccessPolicyProvider.overrideWithValue(stubNetworkPolicy()),
  ...accountProviderOverrides(
    credentialStore: FakeCredentialStore(
      values: const {'100': Credential(accessToken: 'a', refreshToken: 'r')},
    ),
    metadataRepository: FakeAccountMetadataRepository(
      accounts: const [Account(id: '100', userId: 100, name: 'tester')],
      currentId: '100',
    ),
  ),
];

void main() {
  for (final MapEntry(key: name, value: page) in _pages.entries) {
    localeLayoutMatrix('settings: $name', (tester, locale, profile) async {
      installMemoryPreferences();
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          overrides: _overrides(locale),
          home: page,
        ),
      );
      await settleLayout(tester);
      await expectPageLayoutIntact(tester, locale: locale, profile: profile);
    });
  }
}
