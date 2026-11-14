import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/translation/translation_service.dart'
    show translationCredentialStoreProvider;
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/pages/account_settings_page.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations_zh.dart';

import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart';
import 'helpers/view_size.dart';

List<Override> _overrides() => [
  translationCredentialStoreProvider.overrideWithValue(FakeTranslationStore()),
  networkAccessPolicyProvider.overrideWithValue(stubNetworkPolicy()),
  ...accountProviderOverrides(
    credentialStore: FakeCredentialStore(
      values: const {'100': Credential(accessToken: 'a', refreshToken: 'r')},
    ),
  ),
];

void main() {
  final zh = AppLocalizationsZh();

  testWidgets(
    'wide desktop uses master-detail with nested navigation; below 840dp stays single column',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final router = pixivRouter(settingsIndexPath);
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          overrides: _overrides(),
          builder: promptHostBuilder,
        ),
      );
      await tester.pumpAndSettle();

      // Master-detail mounts the initial detail page without a redundant back button.
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(AccountSettingsPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AccountSettingsPage),
          matching: find.byType(BackButton),
        ),
        findsNothing,
      );

      // Selecting Network swaps the detail pane without popping SettingsPage.
      final networkLabel = SettingsPageRef.network.title(zh)!;
      final networkRow = find.text(networkLabel);
      await tester.ensureVisible(networkRow);
      await tester.pump();
      await tester.tap(networkRow);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkSettingsPage), findsOneWidget);
      expect(router.state.uri.path, settingsIndexPath);

      // Pushing a child inside the detail pane keeps SettingsPage mounted.
      final advancedLabel = SettingsPageRef.networkAdvanced.title(zh)!;
      await tester.scrollUntilVisible(
        find.text(advancedLabel),
        300,
        scrollable: find.descendant(
          of: find.byType(NetworkSettingsPage),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text(advancedLabel));
      await tester.pumpAndSettle();
      expect(find.byType(NetworkAdvancedSettingsPage), findsOneWidget);
      final nestedBack = find.descendant(
        of: find.byType(NetworkAdvancedSettingsPage),
        matching: find.byType(BackButton),
      );
      expect(nestedBack, findsOneWidget);

      await tester.tap(nestedBack);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkSettingsPage), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);

      // Below 840dp content width falls back to the single-column index.
      setViewSize(tester, const Size(800, 8000));
      await tester.pump();
      expect(find.byType(NetworkSettingsPage), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
