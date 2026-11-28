import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';

import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/app_dialog.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/account_transfer_service.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/auth/pkce.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/core/platform/platform_caps.dart';
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
  Future<TransferImportResult> importText(String raw) => importFromClipboard();

  @override
  Future<void> exportCurrentToClipboard() async {}

  @override
  Future<void> exportRefreshTokenToClipboard() async {}
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

    testWidgets(
      'proxy notice dialog appears once, remembers acknowledgement, and shows inline hint',
      (tester) async {
        final pushed = <String>[];
        final router = GoRouter(
          initialLocation: '/login',
          routes: [
            GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
            GoRoute(
              path: '/login/web',
              builder: (context, state) {
                pushed.add(state.uri.toString());
                return Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('close-web'),
                  ),
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await seedSettings(
          const AppSettings(
            guideCompleted: false,
            languageTag: 'zh-CN',
            themeCode: AppSettings.systemTheme,
          ),
        );
        await tester.pumpWidget(
          localizedRouterApp(
            router,
            locale: const Locale('zh', 'CN'),
            overrides: [
              ...accountProviderOverrides(),
              networkAccessPolicyProvider.overrideWithValue(
                stubNetworkPolicy(),
              ),
            ],
            builder: promptHostBuilder,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Divider), findsNothing);

        await tester.tap(find.widgetWithText(ReplicaButton, '登录'));
        await tester.pumpAndSettle();

        final dialog = find.byType(AppAlertDialog);
        expect(dialog, findsOneWidget);
        expect(find.text('提示'), findsOneWidget);
        expect(find.text('取消'), findsOneWidget);
        expect(find.text('我已开启代理'), findsOneWidget);

        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(pushed, isEmpty);

        // Confirm once: pushes /login/web and remembers acknowledgement.
        await tester.tap(find.widgetWithText(ReplicaButton, '登录'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('我已开启代理'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(pushed, ['/login/web']);

        await tester.tap(find.text('close-web'));
        await tester.pumpAndSettle();

        // Second tap skips the blocking dialog and goes straight to /login/web.
        await tester.tap(find.widgetWithText(ReplicaButton, '登录'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(pushed, ['/login/web', '/login/web']);
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

    testWidgets(
      'reduced-motion external callback from /login/web keeps PKCE session and preserves first/return flags',
      (tester) async {
        await seedAccounts(const []);
        final oauth = OAuthService(
          client: MockClient((request) async {
            expect(request.url.path, '/auth/token');
            return jsonResponse({
              'access_token': 'tok-a',
              'refresh_token': 'tok-r',
              'expires_in': 3600,
              'user': {
                'id': '300',
                'name': 'ReducedMotionUser',
                'mail_address': '',
                'profile_image_urls': {'px_170x170': ''},
                'is_premium': false,
              },
            });
          }),
        );
        final router = createPixivRouter(
          initialLocation: '/login?first=true&return=true',
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: localizedRouterApp(
              router,
              overrides: [
                ...accountProviderOverrides(
                  credentialStore: FakeCredentialStore(),
                ),
                oauthServiceProvider.overrideWithValue(oauth),
                platformCapsProvider.overrideWithValue(
                  const PlatformCaps(isLinux: true),
                ),
              ],
              builder: promptHostBuilder,
            ),
          ),
        );
        await tester.pumpAndSettle();

        unawaited(router.push<void>('/login/web'));
        await tester.pumpAndSettle();
        expect(oauth.hasLiveSession, isTrue);

        unawaited(
          routeExternalIntent(
            router,
            const RoutedAndroidIntent(AccountCallbackRoute('rm-code')),
          ),
        );
        await tester.pumpAndSettle();

        // /login/web disposal under Duration.zero must not wipe the verifier,
        // and the callback completes sign-in to /recommended.
        expect(router.state.uri.path, '/recommended');
      },
    );

    testWidgets('user agreement and network help buttons keep >=48dp targets', (
      tester,
    ) async {
      await pumpLogin(tester, size: const Size(390, 1000));
      final agreementSize = tester.getSize(
        find.widgetWithText(TextButton, '《Parfait 用户使用协议》'),
      );
      expect(agreementSize.height, greaterThanOrEqualTo(48));
      final helpSize = tester.getSize(
        find.widgetWithIcon(IconButton, AppIcons.info),
      );
      expect(helpSize.width, greaterThanOrEqualTo(48));
      expect(helpSize.height, greaterThanOrEqualTo(48));
    });
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
