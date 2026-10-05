import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// The real router with [row] on a plain pushed route, so a tap goes
/// through the `openUser` facade.
Future<GoRouter> _pumpOnRouter(WidgetTester tester, Widget row) async {
  final router = createPixivRouter(initialLocation: '/recommended');
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: accountProviderOverrides(
        credentialStore: FakeCredentialStore(
          values: const {
            '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
          },
        ),
        metadataRepository: FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 't')],
          currentId: '100',
        ),
      ),
      child: MaterialApp.router(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: const [Locale('zh')],
        locale: const Locale('zh'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  router.routerDelegate.navigatorKey.currentState!.push(
    PageRouteBuilder<void>(
      pageBuilder: (context, _, _) => Scaffold(
        body: Center(child: SizedBox(width: 300, child: row)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return router;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('the whole row is one 48dp target that opens the profile', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      final router = await _pumpOnRouter(
        tester,
        const AuthorRow(userId: 42, name: 'author'),
      );

      final target = find.byType(InkWell);
      expect(target, findsOneWidget);
      expect(
        tester.getSize(target).height,
        greaterThanOrEqualTo(AuthorRow.minHeight),
      );
      // The target spans the row, not just the name text.
      expect(tester.getSize(target).width, 300);

      // A tap well right of the name still lands.
      await tester.tapAt(
        tester.getRect(target).centerRight - const Offset(8, 0),
      );
      await tester.pump();
      expect(router.state.uri.path, '/recommended/user/42');
    });
  });

  testWidgets('reads as one button with the name and a hint', (tester) async {
    final semantics = tester.ensureSemantics();
    await mockNetworkImagesFor(() async {
      await _pumpOnRouter(
        tester,
        AuthorRow(
          userId: 42,
          name: 'author',
          trailing: IconButton(
            tooltip: 'follow',
            onPressed: () {},
            icon: const Icon(Icons.add),
          ),
        ),
      );

      final rowTarget = find.ancestor(
        of: find.text('author'),
        matching: find.byType(InkWell),
      );
      expect(
        tester.getSemantics(rowTarget),
        isSemantics(
          label: 'author',
          hint: '打开作者主页',
          isButton: true,
          hasTapAction: true,
        ),
      );
      // The trailing action keeps its own node outside the row's target.
      expect(
        tester.getSemantics(find.byType(IconButton)),
        isSemantics(tooltip: 'follow', isButton: true),
      );
      expect(
        find.descendant(of: rowTarget, matching: find.byType(IconButton)),
        findsNothing,
      );
    });
    semantics.dispose();
  });
}
