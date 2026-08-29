import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/platform/root_back_coordinator.dart';
import 'package:pixiv_func/features/home/home_page.dart';
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
  const _StaticMetadataRepository(this.snapshot);

  final AccountMetadataSnapshot snapshot;

  @override
  Future<AccountMetadataSnapshot> load() async => snapshot;

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
      'U4: exit hint snackbar lifetime equals the root back exit window',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(
            const _StaticCredentialStore(),
          ),
          accountMetadataRepositoryProvider.overrideWithValue(
            const _StaticMetadataRepository(
              AccountMetadataSnapshot(
                accounts: [Account(id: '100', userId: 100, name: 'tester')],
                currentId: '100',
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    // First root back press arms the exit window and shows the hint.
    await tester.binding.handlePopRoute();
    await tester.pump();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    // The hint must not outlive the window it describes (U4: the default
    // 4-second SnackBar was still showing after the window had closed).
    expect(snackBar.duration, RootBackCoordinator.exitWindow);
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(find.text('再按一次退出'), findsOneWidget);

    // A second press inside the window exits via SystemNavigator.pop; in
    // the test environment that is a no-op that must not throw.
    await tester.binding.handlePopRoute();
    await tester.pump();
  });

  testWidgets('root back coordinator window is one second', (tester) async {
    expect(RootBackCoordinator.exitWindow, const Duration(seconds: 1));
  });
}