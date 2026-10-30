import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/settings_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart';

void main() {
  for (final closed in [false, true]) {
    testWidgets(
      closed
          ? 'a removal that fails after its page closed is reported'
          : 'a removal that fails is reported and its row comes back',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final metadata = FakeAccountMetadataRepository(
          accounts: const [
            Account(id: '1', userId: 1, name: 'first'),
            Account(id: '2', userId: 2, name: 'second'),
          ],
          currentId: '1',
        );
        await tester.pumpWidget(
          localizedApp(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(
                FakeSettingsRepository(baseTestSettings()),
              ),
              accountMetadataRepositoryProvider.overrideWithValue(metadata),
              credentialStoreProvider.overrideWithValue(FakeCredentialStore()),
            ],
            builder: promptHostBuilder,
            navigatorKey: navigator,
            home: const SizedBox(),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => AccountSettingsPage()),
          ),
        );
        await tester.pumpAndSettle();
        final second = find.widgetWithText(ListTile, 'second');
        await tester.tap(
          find.descendant(
            of: second,
            matching: find.byIcon(Icons.delete_outline),
          ),
        );
        await tester.pumpAndSettle();
        metadata.saveGate = Future<void>.error(StateError('disk full'))
          ..ignore();

        await tester.tap(find.text('确定'));
        await tester.pump();
        if (closed) {
          // The stack is replaced, without a transition, while the row
          // plays its exit.
          unawaited(
            navigator.currentState!.pushAndRemoveUntil(
              PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => const SizedBox(),
                transitionDuration: Duration.zero,
              ),
              (_) => false,
            ),
          );
        }
        await tester.pumpAndSettle();

        expect(find.textContaining('设置保存失败'), findsOneWidget);
        if (closed) {
          expect(find.byType(AccountSettingsPage), findsNothing);
        } else {
          expect(
            tester
                .getSize(
                  find.ancestor(of: second, matching: find.byType(Removable)),
                )
                .height,
            greaterThan(0),
          );
        }
        expect(metadata.accounts, hasLength(2));
      },
    );
  }
}
