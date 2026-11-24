import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/app_dialog.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/app/widgets/replica_switch_tile.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/auth/pkce.dart';
import 'package:parfait/core/network/compat/network_contracts.dart'
    as network_contracts;
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'dart:async';

import 'helpers/fake_account.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';
import 'helpers/settings_world.dart';
import 'helpers/view_size.dart';
import 'package:parfait/app/icons/app_icons.dart';

/// Clipboard import stub whose result future the test controls, so the
/// busy state can be observed deterministically.
class _ControlledTransferService implements AccountTransferService {
  final completer = Completer<TransferImportResult>();
  int importCalls = 0;

  @override
  Future<TransferImportResult> importFromClipboard() {
    importCalls++;
    return completer.future;
  }

  @override
  Future<void> exportCurrentToClipboard() async {}
}

/// Settings storage stub: serves a fixed snapshot and records writes.
void main() {
  Future<void> pumpLogin(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool isFirst = false,
    VoidCallback? onRegister,
    VoidCallback? onLogin,
    VoidCallback? onClipboardLogin,
    Locale? locale,
    List<Override> extraOverrides = const [],
  }) async {
    setViewSize(tester, size);
    await seedSettings(
      const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...accountProviderOverrides(), ...extraOverrides],
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: localizedApp(
            locale: locale ?? const Locale('zh', 'CN'),
            builder: promptHostBuilder,
            home: LoginPage(
              isFirst: isFirst,
              onRegister: onRegister,
              onLogin: onLogin,
              onClipboardLogin: onClipboardLogin,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('action layering', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    Future<void> expandHelp(WidgetTester tester) async {
      await tester.tap(find.byIcon(AppIcons.info));
      await tester.pumpAndSettle();
    }

    testWidgets('help expansion keeps register and login tappable', (
      tester,
    ) async {
      var registered = 0;
      var loggedIn = 0;
      await pumpLogin(
        tester,
        size: const Size(390, 844),
        onRegister: () => registered++,
        onLogin: () => loggedIn++,
      );
      expect(find.text(zh.networkCompatibilityHint), findsNothing);
      await expandHelp(tester);
      expect(tester.takeException(), isNull);

      // The toggle reveals only the network note…
      expect(find.text(zh.networkCompatibilityHint), findsOneWidget);
      expect(find.text('使用剪贴板数据登录'), findsOneWidget);
      expect(find.textContaining('粘贴后请自行清空剪贴板'), findsOneWidget);
      // …and the dead "get more help" affordance is gone.
      expect(find.textContaining('获取更多帮助'), findsNothing);

      // …while the primary row is still present and functional.
      final register = find.widgetWithText(ReplicaButton, '注册');
      final login = find.widgetWithText(ReplicaButton, '登录');
      await tester.ensureVisible(register);
      await tester.ensureVisible(login);
      await tester.pumpAndSettle();
      await tester.tap(register);
      await tester.tap(login);
      expect(registered, 1);
      expect(loggedIn, 1);
    });

    testWidgets('clipboard sign-in is visible without the help toggle', (
      tester,
    ) async {
      await pumpLogin(tester, size: const Size(390, 844));

      final button = find.widgetWithText(TextButton, '使用剪贴板数据登录');
      expect(button, findsOneWidget);
      // Only the risk note stays under it; the how-to line is gone.
      final hint = find.textContaining('粘贴后请自行清空剪贴板');
      expect(hint, findsOneWidget);
      expect(find.textContaining('导出账号凭据'), findsNothing);
      // It sits under the register/login row, above the agreement line.
      final login = find.widgetWithText(ReplicaButton, '登录');
      expect(
        tester.getTopLeft(button).dy,
        greaterThan(tester.getBottomLeft(login).dy),
      );
      expect(
        tester.getBottomLeft(hint).dy,
        lessThan(tester.getTopLeft(find.text('登录即表示你同意')).dy),
      );
    });

    testWidgets('clipboard import shows a busy state and debounces taps', (
      tester,
    ) async {
      final service = _ControlledTransferService();
      await pumpLogin(
        tester,
        size: const Size(390, 844),
        extraOverrides: [
          accountTransferServiceProvider.overrideWithValue(service),
        ],
      );

      final button = find.widgetWithText(TextButton, '使用剪贴板数据登录');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();

      await tester.tap(button);
      await tester.pump();
      expect(service.importCalls, 1);
      // Busy: progress indicator in the label area and the action disabled.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNull);

      // A second tap during the import must not start another one.
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(service.importCalls, 1);

      service.completer.complete(
        const TransferImportResult(
          account: Account(id: '1', userId: 1, name: 'Tester'),
          clipboardCleared: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    });

    testWidgets('register and login open the proxy notice dialog', (
      tester,
    ) async {
      await pumpLogin(tester, size: const Size(390, 844));

      await tester.tap(find.widgetWithText(ReplicaButton, '登录'));
      await tester.pumpAndSettle();

      // The proxy notice stays a dialog on every breakpoint (D7).
      final dialog = find.byType(AppAlertDialog);
      expect(dialog, findsOneWidget);
      expect(find.text('提示'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('我已开启代理'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets(
      'compatPrefer renders enabled and restores after toggling off and back on',
      (tester) async {
        final policy = stubNetworkPolicy()
          ..setMode(network_contracts.NetworkMode.compatPrefer);
        await pumpLogin(
          tester,
          extraOverrides: [
            networkAccessPolicyProvider.overrideWithValue(policy),
          ],
        );

        ReplicaSwitchTile tile() =>
            tester.widget<ReplicaSwitchTile>(find.byType(ReplicaSwitchTile));
        expect(tile().value, isTrue);

        await tester.tap(find.byType(ReplicaSwitchTile));
        await tester.pumpAndSettle();
        expect(tile().value, isFalse);
        expect(policy.mode, network_contracts.NetworkMode.directOnly);

        await tester.tap(find.byType(ReplicaSwitchTile));
        await tester.pumpAndSettle();
        expect(tile().value, isTrue);
        expect(policy.mode, network_contracts.NetworkMode.compatPrefer);
      },
    );

    testWidgets(
      'add-account clipboard import pops login and queues clipboard-replaced toast without dropping success toast',
      (tester) async {
        final service = _ControlledTransferService();
        setViewSize(tester, const Size(390, 844));
        await seedSettings(
          const AppSettings(
            guideCompleted: true,
            languageTag: 'zh-CN',
            themeCode: AppSettings.systemTheme,
          ),
        );
        final router = GoRouter(
          initialLocation: '/settings/account',
          routes: [
            GoRoute(
              path: '/settings/account',
              builder: (_, _) => const Scaffold(body: Text('account-origin')),
            ),
            GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...accountProviderOverrides(
                credentialStore: FakeCredentialStore(
                  values: const {
                    '100': Credential(accessToken: 'a', refreshToken: 'r'),
                  },
                ),
              ),
              accountTransferServiceProvider.overrideWithValue(service),
            ],
            child: localizedRouterApp(
              router,
              locale: const Locale('zh', 'CN'),
              builder: promptHostBuilder,
            ),
          ),
        );
        await tester.pumpAndSettle();
        unawaited(router.push<void>('/login'));
        await tester.pumpAndSettle();
        expect(find.byType(LoginPage), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, '使用剪贴板数据登录'));
        await tester.pump();
        service.completer.complete(
          const TransferImportResult(
            account: Account(id: '2', userId: 2, name: 'Second'),
            clipboardCleared: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('account-origin'), findsOneWidget);
        expect(find.byType(LoginPage), findsNothing);
        // First toast stays active while second waits in PromptHost's queue.
        expect(find.text(zh.accountTransferImported), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(find.text(zh.accountTransferClipboardReplaced), findsOneWidget);
      },
    );

    testWidgets(
      'external OAuth callback shows busy spinner, replaces /login without stacking, and pops back on add-account',
      (tester) async {
        setViewSize(tester, const Size(390, 844));
        await seedSettings(
          const AppSettings(
            guideCompleted: true,
            languageTag: 'zh-CN',
            themeCode: AppSettings.systemTheme,
          ),
        );
        final exchangeGate = Completer<OAuthResult>();
        final oauth = _ControlledOAuthService(exchangeGate);
        final router = pixivRouter('/recommended');
        await tester.pumpWidget(
          localizedRouterApp(
            router,
            overrides: [
              ...accountProviderOverrides(
                credentialStore: FakeCredentialStore(
                  values: const {
                    '100': Credential(accessToken: 'a', refreshToken: 'r'),
                  },
                ),
              ),
              oauthServiceProvider.overrideWithValue(oauth),
            ],
            builder: promptHostBuilder,
          ),
        );
        await tester.pumpAndSettle();

        unawaited(router.push<void>('/login'));
        await tester.pumpAndSettle();
        unawaited(
          routeExternalIntent(
            router,
            const RoutedAndroidIntent(AccountCallbackRoute('code-1')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        // Top-level /login/callback replaces /login (never 2+ LoginPages stacked).
        expect(find.byType(LoginPage), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<ReplicaButton>(find.widgetWithText(ReplicaButton, '登录'))
              .onPressed,
          isNull,
        );

        exchangeGate.complete(
          const OAuthResult(
            accountId: '200',
            profile: OAuthUserProfile(
              userId: 200,
              name: 'Second',
              mailAddress: '',
              profileImageUrl: null,
              isPremium: false,
            ),
            credential: Credential(accessToken: 'a2', refreshToken: 'r2'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LoginPage), findsNothing);
        expect(router.state.uri.path, '/recommended');
      },
    );
  });
}

class _ControlledOAuthService extends OAuthService {
  _ControlledOAuthService(this._gate);

  final Completer<OAuthResult> _gate;

  @override
  PixivCallback validateRedirect(Uri uri) =>
      PixivCallbackCode(uri.queryParameters['code'] ?? '');

  @override
  Future<OAuthResult> exchangeCode(String code) => _gate.future;
}
