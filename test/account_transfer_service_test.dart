import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/account_transfer.dart';
import 'package:pixiv_func/core/auth/account_transfer_service.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/platform/account_transfer_clipboard.dart';

const _sourceAccount = Account(
  id: '42',
  userId: 42,
  name: 'clipboard name must not be trusted',
  mailAddress: 'clipboard@example.invalid',
);

const _credential = Credential(
  accessToken: 'access-token-for-service-test',
  refreshToken: 'refresh-token-for-service-test',
);

class _Metadata implements AccountMetadataRepository {
  List<Account> accounts = [];
  String? currentId;
  bool failSave = false;

  @override
  Future<AccountMetadataSnapshot> load() async =>
      AccountMetadataSnapshot(accounts: accounts, currentId: currentId);

  @override
  Future<void> save(List<Account> next, String? nextCurrentId) async {
    if (failSave) throw AccountDataException('metadata write failed');
    accounts = List.of(next);
    currentId = nextCurrentId;
  }
}

class _Credentials implements CredentialStore {
  final values = <String, Credential>{};

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

class _Clipboard implements TransferClipboard {
  String? text;
  bool replaceBeforeClear = false;
  int readCount = 0;
  int clearCount = 0;
  int writeCount = 0;

  @override
  Future<void> write(String value, {required Duration clearAfter}) async {
    text = value;
    writeCount++;
  }

  @override
  Future<TransferClipboardContent?> read() async {
    readCount++;
    final value = text;
    return value == null
        ? null
        : TransferClipboardContent(
            text: value,
            fingerprint: transferClipboardFingerprint(value),
          );
  }

  @override
  Future<bool> clearIfCurrent(String fingerprint) async {
    clearCount++;
    if (replaceBeforeClear) {
      text = 'user copied something else';
    }
    final value = text;
    if (value == null || transferClipboardFingerprint(value) != fingerprint) {
      return false;
    }
    text = null;
    return true;
  }

  @override
  Future<TransferClipboardCapabilities> capabilities() async =>
      const TransferClipboardCapabilities(sensitiveMarkSupported: true);
}

class _Verifier implements TransferCredentialVerifier {
  _Verifier(this.result);

  final Future<VerifiedTransferAccount> Function(TransferAccountPayload) result;
  int calls = 0;

  @override
  Future<VerifiedTransferAccount> verify(TransferAccountPayload payload) {
    calls++;
    return result(payload);
  }
}

(ProviderContainer, AccountStore, _Credentials, _Metadata) _container() {
  final credentials = _Credentials();
  final metadata = _Metadata();
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(metadata),
    ],
  );
  addTearDown(container.dispose);
  return (
    container,
    container.read(accountStoreProvider.notifier),
    credentials,
    metadata,
  );
}

AccountTransferService _service({
  required AccountStore accountStore,
  required _Credentials credentials,
  required _Clipboard clipboard,
  required TransferCredentialVerifier verifier,
}) => AccountTransferService(
  accountStore: accountStore,
  credentialStore: credentials,
  verifier: verifier,
  clipboard: clipboard,
);

Map<String, dynamic> _authoritativeDetail({int id = 42}) => {
  'user': {
    'id': id,
    'name': 'server authoritative name',
    'account': 'server-account',
    'profile_image_urls': {'medium': 'https://i.pximg.net/server-avatar.jpg'},
  },
  'profile': {
    'background_image_url': null,
    'webpage': null,
    'twitter_url': null,
    'pawoo_url': null,
    'total_follow_users': 0,
    'total_mypixiv_users': 0,
    'total_illusts': 0,
    'total_manga': 0,
    'total_novels': 0,
    'total_illust_bookmarks_public': 0,
    'total_illust_series': 0,
    'total_novel_series': 0,
  },
};

void main() {
  test(
    'successful import uses server-authoritative metadata and clears owned clipboard',
    () async {
      final (container, accounts, credentials, metadata) = _container();
      await container.read(accountStoreProvider.future);
      final clipboard = _Clipboard();
      final envelope = TransferEnvelope.create(
        account: _sourceAccount,
        credential: _credential,
      );
      clipboard.text = envelope.encode();
      final verifier = _Verifier((payload) async {
        expect(payload.accountId, '42');
        return const VerifiedTransferAccount(
          account: Account(
            id: '42',
            userId: 42,
            name: 'authoritative server name',
            profileImageUrl: 'https://i.pximg.net/server-avatar.jpg',
          ),
          credential: _credential,
        );
      });

      final result = await _service(
        accountStore: accounts,
        credentials: credentials,
        clipboard: clipboard,
        verifier: verifier,
      ).importFromClipboard();

      expect(result.account.name, 'authoritative server name');
      expect(result.clipboardCleared, isTrue);
      expect(clipboard.text, isNull);
      expect(verifier.calls, 1);
      expect(metadata.accounts.single.name, 'authoritative server name');
      expect(await credentials.read('42'), same(_credential));
    },
  );

  test(
    'invalid credential leaves account metadata and secure credentials untouched',
    () async {
      final (container, accounts, credentials, metadata) = _container();
      await container.read(accountStoreProvider.future);
      final clipboard = _Clipboard();
      final envelope = TransferEnvelope.create(
        account: _sourceAccount,
        credential: _credential,
      );
      clipboard.text = envelope.encode();
      final verifier = _Verifier((_) async {
        throw const AccountTransferException(
          AccountTransferErrorCode.credentialInvalid,
          'credential rejected',
        );
      });

      await expectLater(
        _service(
          accountStore: accounts,
          credentials: credentials,
          clipboard: clipboard,
          verifier: verifier,
        ).importFromClipboard(),
        throwsA(
          isA<AccountTransferException>().having(
            (error) => error.code,
            'code',
            AccountTransferErrorCode.credentialInvalid,
          ),
        ),
      );
      expect(metadata.accounts, isEmpty);
      expect(credentials.values, isEmpty);
      expect(clipboard.text, isNull);
    },
  );

  test(
    'conditional clear does not erase content copied after import started',
    () async {
      final (container, accounts, credentials, _) = _container();
      await container.read(accountStoreProvider.future);
      final clipboard = _Clipboard()..replaceBeforeClear = true;
      final envelope = TransferEnvelope.create(
        account: _sourceAccount,
        credential: _credential,
      );
      clipboard.text = envelope.encode();
      final verifier = _Verifier(
        (_) async => const VerifiedTransferAccount(
          account: Account(id: '42', userId: 42, name: 'server'),
          credential: _credential,
        ),
      );

      final result = await _service(
        accountStore: accounts,
        credentials: credentials,
        clipboard: clipboard,
        verifier: verifier,
      ).importFromClipboard();

      expect(result.clipboardCleared, isFalse);
      expect(clipboard.text, 'user copied something else');
    },
  );

  test(
    'metadata failure is reported as import failure without a half account',
    () async {
      final (container, accounts, credentials, metadata) = _container();
      await container.read(accountStoreProvider.future);
      metadata.failSave = true;
      final clipboard = _Clipboard();
      final envelope = TransferEnvelope.create(
        account: _sourceAccount,
        credential: _credential,
      );
      clipboard.text = envelope.encode();

      await expectLater(
        _service(
          accountStore: accounts,
          credentials: credentials,
          clipboard: clipboard,
          verifier: _Verifier(
            (_) async => const VerifiedTransferAccount(
              account: Account(id: '42', userId: 42, name: 'server'),
              credential: _credential,
            ),
          ),
        ).importFromClipboard(),
        throwsA(
          isA<AccountTransferException>().having(
            (error) => error.code,
            'code',
            AccountTransferErrorCode.storageFailure,
          ),
        ),
      );
      expect(metadata.accounts, isEmpty);
      expect(credentials.values, isEmpty);
      expect(clipboard.text, isNull);
    },
  );

  test(
    'export reads the current secure credential and schedules bounded clipboard expiry',
    () async {
      final (container, accounts, credentials, _) = _container();
      await container.read(accountStoreProvider.future);
      await accounts.upsertAccount(_sourceAccount, _credential);
      final clipboard = _Clipboard();
      await _service(
        accountStore: accounts,
        credentials: credentials,
        clipboard: clipboard,
        verifier: _Verifier((_) async => throw StateError('unused')),
      ).exportCurrentToClipboard();

      expect(clipboard.writeCount, 1);
      final parsed = TransferEnvelope.parse(clipboard.text!);
      expect(parsed.payload.accountId, '42');
      expect(parsed.payload.credential, isNotNull);
    },
  );

  test(
    'clipboard read is explicit and malformed input is not cleared',
    () async {
      final (container, accounts, credentials, _) = _container();
      await container.read(accountStoreProvider.future);
      final clipboard = _Clipboard()..text = 'external clipboard text';

      await expectLater(
        _service(
          accountStore: accounts,
          credentials: credentials,
          clipboard: clipboard,
          verifier: _Verifier((_) async => throw StateError('unused')),
        ).importFromClipboard(),
        throwsA(
          isA<AccountTransferException>().having(
            (error) => error.code,
            'code',
            AccountTransferErrorCode.corrupt,
          ),
        ),
      );
      expect(clipboard.readCount, 1);
      expect(clipboard.clearCount, 0);
      expect(clipboard.text, 'external clipboard text');
    },
  );

  test(
    'production verifier sends supplied credential and trusts server metadata',
    () async {
      final (container, accounts, credentials, _) = _container();
      await container.read(accountStoreProvider.future);
      final requests = <http.Request>[];
      final apiClient = PixivHttpClient(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode(_authoritativeDetail()), 200);
        }),
        accountStore: accounts,
        credentialStore: credentials,
        oauthService: OAuthService(
          client: MockClient((_) async => http.Response('{}', 500)),
        ),
      );
      final oauthService = OAuthService(
        client: MockClient((_) async => http.Response('{}', 500)),
      );
      final verifier = PixivTransferCredentialVerifier(
        apiClient: apiClient,
        oauthService: oauthService,
      );

      final result = await verifier.verify(
        const TransferAccountPayload(
          accountId: '42',
          userId: 42,
          credential: _credential,
        ),
      );

      expect(requests.single.url.path, '/v1/user/detail');
      expect(requests.single.url.queryParameters['user_id'], '42');
      expect(
        requests.single.headers['Authorization'],
        'Bearer access-token-for-service-test',
      );
      expect(result.account.name, 'server authoritative name');
      expect(
        result.account.profileImageUrl,
        'https://i.pximg.net/server-avatar.jpg',
      );
      expect(result.account.mailAddress, isNull);
    },
  );
}
