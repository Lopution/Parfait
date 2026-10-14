import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/credential_store.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';

/// Simple in-memory credential store for tests whose account behavior is not
/// itself the subject of the test.
class FakeCredentialStore implements CredentialStore {
  FakeCredentialStore({Map<String, Credential>? values})
    : values = {...?values};

  final Map<String, Credential> values;

  void seed(String accountId, Credential credential) {
    values[accountId] = credential;
  }

  @override
  Future<Credential?> read(String accountId) async => values[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async {
    values[accountId] = credential;
  }

  @override
  Future<void> delete(String accountId) async {
    values.remove(accountId);
  }
}

/// Simple mutable account metadata repository for tests with ordinary
/// successful load/save behavior.
class FakeAccountMetadataRepository implements AccountMetadataRepository {
  FakeAccountMetadataRepository({
    Iterable<Account> accounts = const [],
    this.currentId,
  }) : accounts = List<Account>.of(accounts);

  /// [account] alone, signed in.
  FakeAccountMetadataRepository.signedIn(Account account)
    : this(accounts: [account], currentId: account.id);

  List<Account> accounts;
  String? currentId;

  @override
  Future<AccountMetadataSnapshot> load() async => AccountMetadataSnapshot(
    accounts: List<Account>.of(accounts),
    currentId: currentId,
  );

  @override
  Future<void> save(List<Account> next, String? nextCurrentId) async {
    accounts = List<Account>.of(next);
    currentId = nextCurrentId;
  }
}

/// Standard overrides for account-backed providers.
/// The account most widget tests sign in as.
const testerAccount = Account(id: '100', userId: 100, name: 'tester');

/// [accountProviderOverrides] with [account] alone signed in.
List<Override> signedInAccountOverrides([Account account = testerAccount]) =>
    accountProviderOverrides(
      credentialStore: FakeCredentialStore(
        values: {
          account.id: Credential(
            accessToken: 'a-${account.id}',
            refreshToken: 'r-${account.id}',
          ),
        },
      ),
      metadataRepository: FakeAccountMetadataRepository.signedIn(account),
    );

List<Override> accountProviderOverrides({
  CredentialStore? credentialStore,
  AccountMetadataRepository? metadataRepository,
}) {
  return [
    credentialStoreProvider.overrideWithValue(
      credentialStore ?? FakeCredentialStore(),
    ),
    accountMetadataRepositoryProvider.overrideWithValue(
      metadataRepository ?? FakeAccountMetadataRepository(),
    ),
  ];
}

/// An [AccountStore] that is ready with [accounts] signed in and
/// [currentId] (the first account by default) current, for tests that need
/// accounts but none of the stores behind the real one.
class StubAccountStore extends AccountStore {
  StubAccountStore({
    this.accounts = const [Account(id: '100', userId: 100, name: 'a')],
    String? currentId,
  }) : _initialId = currentId ?? accounts.first.id;

  final List<Account> accounts;
  final String _initialId;

  @override
  Future<AccountState> build() async => _ready(_initialId);

  /// Makes [accountId] current without the metadata repository or a
  /// network session.
  void switchCurrentTo(String accountId) =>
      state = AsyncData(_ready(accountId));

  AccountState _ready(String currentId) => AccountState(
    status: AccountStatus.ready,
    accounts: accounts,
    currentId: currentId,
  );
}

/// Two signed-in accounts, '100' and '200', for account-switch tests.
const stubAccountPair = [
  Account(id: '100', userId: 100, name: 'a'),
  Account(id: '200', userId: 200, name: 'b'),
];

/// A container signed in as [account] whose [pixivHttpClientProvider]
/// sends through [transport], with [overrides] added; a token refresh fails
/// the test. [others] are signed in too, each with the access token
/// `access-<id>`. Returns once the accounts have loaded.
Future<ProviderContainer> signedInApiContainer(
  http.Client transport, {
  List<Override> overrides = const [],
  Account account = testerAccount,
  Credential credential = const Credential(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
  ),
  List<Account> others = const [],
}) async {
  final credentials = FakeCredentialStore()..seed(account.id, credential);
  for (final other in others) {
    credentials.seed(
      other.id,
      Credential(
        accessToken: 'access-${other.id}',
        refreshToken: 'refresh-${other.id}',
      ),
    );
  }
  late final PixivHttpClient client;
  final container = ProviderContainer.test(
    overrides: [
      ...accountProviderOverrides(
        credentialStore: credentials,
        metadataRepository: FakeAccountMetadataRepository(
          accounts: [account, ...others],
          currentId: account.id,
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (request) async => fail('a token refresh is not expected here'),
          ),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) => client),
      ...overrides,
    ],
  );
  client = PixivHttpClient(
    client: transport,
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return container;
}
