import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/core/i18n/replica_language.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/features/onboarding/language_page.dart';
import 'package:parfait/features/onboarding/user_agreement_page.dart';
import 'package:parfait/features/onboarding/welcome_page.dart';

import '../helpers/fake_account.dart';
import '../helpers/locale_layout.dart';
import '../helpers/settings_world.dart';
import '../helpers/test_preferences.dart';

/// First-run pages. Login and language read the persisted language
/// tag; the others the app locale — the world sets both.
final _pages = <String, (Widget, {int actions})>{
  'login': (const LoginPage(isFirst: true), actions: 2),
  'welcome': (const WelcomePage(), actions: 1),
  'language': (const LanguagePage(), actions: 1),
  'user agreement': (const UserAgreementPage(), actions: 0),
};

void main() {
  for (final MapEntry(key: name, value: (page, :actions)) in _pages.entries) {
    localeLayoutMatrix('entry: $name', (tester, locale, profile) async {
      installMemoryPreferences();
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          overrides: [
            ...accountProviderOverrides(),
            settingsRepositoryProvider.overrideWithValue(
              FakeSettingsRepository(
                baseTestSettings(
                  languageTag: ReplicaLanguage.fromTag(locale.languageCode).tag,
                ),
              ),
            ),
          ],
          home: page,
        ),
      );
      await settleLayout(tester);
      await expectPageLayoutIntact(tester, locale: locale, profile: profile);

      // The primary actions stay reachable: pinned on tall screens,
      // scrolled to on short ones.
      final buttons = find.byType(ReplicaButton);
      expect(buttons, findsNWidgets(actions));
      for (var i = 0; i < actions; i++) {
        await tester.ensureVisible(buttons.at(i));
        await settleLayout(tester);
        expect(
          tester.getRect(buttons.at(i)).bottom,
          lessThanOrEqualTo(profile.size.height),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
