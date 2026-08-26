import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/features/home/home_page.dart';
import 'package:pixiv_func/features/login/login_page.dart';
import 'package:pixiv_func/features/onboarding/startup_gate.dart';
import 'package:pixiv_func/features/onboarding/welcome_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _StaticCredentialStore implements CredentialStore {
  const _StaticCredentialStore();

  @override
  Future<Credential?> read(String accountId) async =>
      Credential(accessToken: 'a-$accountId', refreshToken: 'r-$accountId');

  @override
  Future<void> write(String accountId, Credential credential) async {}

  @override
  Future<void> delete(String accountId) async {}
}

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

Widget _wrap({
  required AppSettings settings,
  required AccountMetadataSnapshot snapshot,
  bool brokenStore = false,
  bool corruptMetadata = false,
}) {
  return ProviderScope(
    overrides: [
      credentialStoreProvider.overrideWithValue(
        brokenStore
            ? const _FailingCredentialStore()
            : const _StaticCredentialStore(),
      ),
      accountMetadataRepositoryProvider.overrideWithValue(
        _StaticMetadataRepository(snapshot, corrupt: corruptMetadata),
      ),
    ],
    child: MaterialApp(home: StartupGate(settings: settings)),
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
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('guide not completed shows the welcome shell', (tester) async {
    await tester.pumpWidget(_wrap(
      settings: AppSettings.defaults(),
      snapshot: const AccountMetadataSnapshot(accounts: []),
    ));

    expect(find.byType(WelcomePage), findsOneWidget);
    expect(find.text('感谢使用Pixiv Func'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });

  testWidgets('guide completed without an account shows the login page',
      (tester) async {
    await tester.pumpWidget(_wrap(
      settings: const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
      snapshot: const AccountMetadataSnapshot(accounts: []),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('guide completed with a usable account shows home',
      (tester) async {
    await tester.pumpWidget(_wrap(
      settings: const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
      snapshot: const AccountMetadataSnapshot(
        accounts: [
          Account(id: '100', userId: 100, name: 'tester'),
        ],
        currentId: '100',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('reauth-required current account falls back to login',
      (tester) async {
    await tester.pumpWidget(_wrap(
      settings: const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
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
    ));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('unreadable credentials fall back to the re-auth flow',
      (tester) async {
    await tester.pumpWidget(_wrap(
      settings: const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
      snapshot: const AccountMetadataSnapshot(
        accounts: [
          Account(id: '100', userId: 100, name: 'tester'),
        ],
        currentId: '100',
      ),
      brokenStore: true,
    ));
    await tester.pumpAndSettle();

    // Keystore failure degrades the account to re-auth required; the gate
    // must not pretend a usable session exists.
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
  });

  testWidgets('corrupt metadata surfaces a retryable error', (tester) async {
    await tester.pumpWidget(_wrap(
      settings: const AppSettings(
        guideCompleted: true,
        languageTag: 'zh-CN',
        themeCode: AppSettings.systemTheme,
      ),
      snapshot: const AccountMetadataSnapshot(accounts: []),
      corruptMetadata: true,
    ));
    await tester.pumpAndSettle();

    expect(find.text('启动时读取账号状态失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(HomePage), findsNothing);
  });
}
