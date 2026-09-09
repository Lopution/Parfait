import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:pixiv_func/app/external_intent_bridge.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/platform/android_intent_channel.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';
import 'package:pixiv_func/features/login/login_page.dart';
import 'package:pixiv_func/features/search/reverse_image_search_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _ScriptedIntentSource implements AndroidIntentSource {
  _ScriptedIntentSource(this.initial);

  final AndroidIntentResult initial;
  final StreamController<AndroidIntentResult> controller =
      StreamController<AndroidIntentResult>.broadcast();

  @override
  Future<AndroidIntentResult> readInitial() async => initial;

  @override
  Stream<AndroidIntentResult> get onNewIntent => controller.stream;

  Future<void> dispose() => controller.close();
}

const _signedInSnapshot = AccountMetadataSnapshot(
  accounts: [Account(id: '100', userId: 100, name: 'tester')],
  currentId: '100',
);

Widget _app(GoRouter router, _ScriptedIntentSource source) {
  final credentials = FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
    },
  );
  final metadata = FakeAccountMetadataRepository(
    accounts: _signedInSnapshot.accounts,
    currentId: _signedInSnapshot.currentId,
  );
  return ProviderScope(
    overrides: [
      ...accountProviderOverrides(
        credentialStore: credentials,
        metadataRepository: metadata,
      ),
    ],
    child: MaterialApp.router(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      routerConfig: router,
      builder: (context, child) => ExternalIntentBridge(
        router: router,
        intentSource: source,
        child: child!,
      ),
    ),
  );
}

Future<({GoRouter router, _ScriptedIntentSource source})> _pump(
  WidgetTester tester, {
  required AndroidIntentResult initial,
  String initialLocation = '/recommended',
}) async {
  final source = _ScriptedIntentSource(initial);
  final router = createPixivRouter(initialLocation: initialLocation);
  addTearDown(source.dispose);
  addTearDown(router.dispose);
  await tester.pumpWidget(_app(router, source));
  await tester.pump();
  return (router: router, source: source);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('cold-start Pixiv links use the recommended branch', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: RoutedAndroidIntent(
        IntentRouter.route(Uri.parse('pixiv://illusts/456')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(result.router.state.uri.path, '/recommended/illust/456');
  });

  testWidgets('cold-start Pixiv Func links use the recommended branch', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: RoutedAndroidIntent(
        IntentRouter.route(Uri.parse('pixivfunc://users/123')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(result.router.state.uri.path, '/recommended/user/123');
  });

  testWidgets(
    'running deep links replace the current branch with recommended',
    (tester) async {
      final result = await _pump(
        tester,
        initial: const IgnoredAndroidIntent('test: no initial intent'),
        initialLocation: '/settings',
      );

      result.source.controller.add(
        RoutedAndroidIntent(
          IntentRouter.route(Uri.parse('https://www.pixiv.net/users/789')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(result.router.state.uri.path, '/recommended/user/789');
    },
  );

  testWidgets('ACTION_SEND pushes the root reverse-image route', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: const IgnoredAndroidIntent('test: no initial intent'),
    );

    result.source.controller.add(
      SharedImageAndroidIntent(
        contentUri: Uri.parse('content://share/1'),
        mimeType: 'image/png',
        sizeBytes: 32,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(result.router.state.uri.path, '/reverse-image');
    expect(find.byType(ReverseImageSearchPage), findsOneWidget);
  });

  testWidgets('rejected intents show the existing rejection snackbar', (
    tester,
  ) async {
    await _pump(
      tester,
      initial: const RejectedAndroidIntent(
        AndroidIntentRejectionCode.invalidViewUri,
        'invalid link',
      ),
    );
    await tester.pump();

    expect(find.text('分享的图片无法使用'), findsOneWidget);
  });

  testWidgets('account callbacks enter the login route with their payload', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: const RoutedAndroidIntent(AccountCallbackRoute('code')),
      initialLocation: '/login',
    );
    await tester.pump();

    expect(result.router.state.uri.path, '/login/callback');
    expect(find.byType(LoginPage), findsNWidgets(2));
    expect(result.router.state.extra, isA<AccountCallbackRoute>());
  });
}
