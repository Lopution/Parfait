import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/credential_store.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/home/home_page.dart';
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/startup_gate.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/features/onboarding/user_agreement_page.dart';
import 'package:parfait/features/onboarding/welcome_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'dart:async';

import 'helpers/fake_account.dart';
import 'helpers/fake_webview.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';

class _StaticMetadataRepository implements AccountMetadataRepository {
  const _StaticMetadataRepository(this.snapshot, {this.corrupt = false});

  final AccountMetadataSnapshot snapshot;
  final bool corrupt;

  @override
  Future<AccountMetadataSnapshot> load() async {
    if (corrupt) throw AccountDataException('corrupt entry');
    return snapshot;
  }

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

class _PendingMetadataRepository implements AccountMetadataRepository {
  final _completer = Completer<AccountMetadataSnapshot>();

  @override
  Future<AccountMetadataSnapshot> load() => _completer.future;

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

const _guided = AppSettings(
  guideCompleted: true,
  languageTag: 'zh-CN',
  themeCode: AppSettings.systemTheme,
);

const _signedIn = AccountMetadataSnapshot(
  accounts: [Account(id: '100', userId: 100, name: 'tester')],
  currentId: '100',
);

Widget _wrap({
  AppSettings settings = _guided,
  AccountMetadataSnapshot snapshot = const AccountMetadataSnapshot(
    accounts: [],
  ),
  bool brokenStore = false,
  bool corruptMetadata = false,
  String? initialLocation,
  bool settingsPending = false,
  AccountMetadataRepository? metadataRepository,
  GoRouter? router,
}) {
  router ??= createPixivRouter(
    initialLocation:
        initialLocation ??
        (settings.guideCompleted ? '/recommended' : '/welcome'),
  );
  return localizedRouterApp(
    router,
    overrides: [
      credentialStoreProvider.overrideWithValue(
        brokenStore
            ? const _FailingCredentialStore()
            : FakeCredentialStore(
                values: {
                  for (final account in snapshot.accounts)
                    account.id: Credential(
                      accessToken: 'a-${account.id}',
                      refreshToken: 'r-${account.id}',
                    ),
                },
              ),
      ),
      accountMetadataRepositoryProvider.overrideWithValue(
        metadataRepository ??
            (corruptMetadata
                ? _StaticMetadataRepository(snapshot, corrupt: corruptMetadata)
                : FakeAccountMetadataRepository(
                    accounts: snapshot.accounts,
                    currentId: snapshot.currentId,
                  )),
      ),
    ],
    builder: (context, child) => StartupGate(
      settings: settings,
      router: router!,
      settingsPending: settingsPending,
      child: child!,
    ),
  );
}

class _FailingCredentialStore implements CredentialStore {
  const _FailingCredentialStore();

  @override
  Future<Credential?> read(String accountId) async =>
      throw CredentialStoreException('read', accountId, 'broken');

  @override
  Future<void> write(String accountId, Credential credential) async {}

  @override
  Future<void> delete(String accountId) async {}
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('guide not completed shows the welcome shell', (tester) async {
    await tester.pumpWidget(_wrap(settings: AppSettings.defaults()));

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('感谢使用 Parfait'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });

  testWidgets('guide completed without an account shows the login page', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets(
    'login remains visible while first account hydration is pending',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          initialLocation: '/login',
          metadataRepository: _PendingMetadataRepository(),
        ),
      );
      await tester.pump();

      // A slow secure/metadata read must not replace the actionable login
      // surface with StartupGate's full-screen spinner.
      expect(find.byType(LoginPage), findsOneWidget);
    },
  );

  testWidgets('signed-in cold start from /splash never shows welcome', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(snapshot: _signedIn, initialLocation: '/splash'),
    );
    // The pending surface is the neutral splash — never WelcomePage.
    expect(find.byType(SplashPage), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);

    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
  });

  testWidgets('guide completed with a usable account shows home', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(snapshot: _signedIn));
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    // The fifth destination is Me; the profile opens from its card.
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('reauth-required current account falls back to login', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        snapshot: const AccountMetadataSnapshot(
          accounts: [
            Account(
              id: '100',
              userId: 100,
              name: 'tester',
              authState: AccountAuthState.reauthRequired,
            ),
          ],
          currentId: '100',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('unreadable credentials fall back to the re-auth flow', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(snapshot: _signedIn, brokenStore: true));
    await tester.pumpAndSettle();

    // Keystore failure degrades the account to re-auth required; the gate
    // must not pretend a usable session exists.
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
  });

  testWidgets('user agreement pushed from login stays reachable', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/login');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        overrides: [
          credentialStoreProvider.overrideWithValue(
            FakeCredentialStore(values: const {}),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            FakeAccountMetadataRepository(),
          ),
        ],
        builder: (context, child) =>
            StartupGate(settings: _guided, router: router, child: child!),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);

    // Pushing the agreement page must not trap the gate: returning a
    // spinner instead of `child` unmounts the Router, whose provider
    // listener is then gone and the gate's scheduled go() can never be
    // consumed — a permanent deadlock on the loading page.
    unawaited(router.push<void>('/user-agreement'));
    await tester.pumpAndSettle();

    expect(find.byType(UserAgreementPage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(router.state.uri.path, '/user-agreement');

    // Back lands on the login page the agreement was pushed from.
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('add account survives the gate rebuilding under it', (
    tester,
  ) async {
    final router = createPixivRouter(initialLocation: '/recommended');
    await tester.pumpWidget(_wrap(snapshot: _signedIn, router: router));
    await tester.pumpAndSettle();
    unawaited(router.push<void>('/login'));
    await tester.pumpAndSettle();
    final accounts = ProviderScope.containerOf(
      tester.element(find.byType(LoginPage)),
    ).read(accountStoreProvider.notifier);

    // A reload passes through loading to a new value, as a token refresh
    // or a settings write rebuilding the gate mid-OAuth does.
    await accounts.reload();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/login');
    expect(find.byType(LoginPage), findsOneWidget);

    // Once the WebView reports the account, the login closes back to the
    // page that opened it.
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
    await tester.tap(find.byType(ReplicaButton).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已开启代理'));
    await tester.pumpAndSettle();
    router.pop(true);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended');
  });

  testWidgets('an image shared into a cold start stays open until back', (
    tester,
  ) async {
    // Android pushes the share over the splash before the account loads.
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
    final metadata = _PendingMetadataRepository();
    final router = createPixivRouter(initialLocation: '/splash');
    await tester.pumpWidget(
      _wrap(snapshot: _signedIn, router: router, metadataRepository: metadata),
    );
    await tester.pump();
    unawaited(router.push<void>('/reverse-image'));
    await tester.pump();
    metadata._completer.complete(_signedIn);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/reverse-image');

    // Back lands on the splash, which is never a destination.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('corrupt metadata surfaces a retryable error', (tester) async {
    await tester.pumpWidget(_wrap(corruptMetadata: true));
    await tester.pumpAndSettle();

    expect(find.text('读取账号状态失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // Retry is the error page's primary action — a filled button, not a
    // low-emphasis text button.
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(HomePage), findsNothing);
  });

  testWidgets('the warm-up draws the ripple and keeps the app mounted', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PipelineWarmup(child: _MountProbe())),
    );
    final probe = tester.state(find.byType(_MountProbe));
    final warmups = find.descendant(
      of: find.byType(PipelineWarmup),
      matching: find.byType(Positioned),
    );
    final sparkle = find.descendant(
      of: warmups,
      matching: find.byType(CustomPaint),
    );
    var sparkleFrames = 0;
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
      if (sparkle.evaluate().isNotEmpty) sparkleFrames++;
    }

    expect(sparkleFrames, greaterThan(0));
    expect(warmups, findsNothing);
    expect(tester.state(find.byType(_MountProbe)), same(probe));
  });
}

class _MountProbe extends StatefulWidget {
  const _MountProbe();

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
