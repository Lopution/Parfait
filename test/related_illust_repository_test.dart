import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/illust/related_illust_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/illust_fixtures.dart';

class _FakeCredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _FakeMetadataRepository implements AccountMetadataRepository {
  @override
  Future<AccountMetadataSnapshot> load() async => const AccountMetadataSnapshot(
    accounts: [Account(id: '100', userId: 100, name: 'tester')],
    currentId: '100',
  );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<PixivRelatedIllustRepository> _repo(MockClient client) async {
  final credentials = _FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final container = ProviderContainer(
    overrides: [
      accountMetadataRepositoryProvider.overrideWithValue(
        _FakeMetadataRepository(),
      ),
      credentialStoreProvider.overrideWithValue(credentials),
    ],
  );
  addTearDown(container.dispose);
  final pixiv = PixivHttpClient(
    client: client,
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return PixivRelatedIllustRepository(pixiv);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        memoryPreferences();
  });

  group('PixivRelatedIllustRepository', () {
    test('requests /v2/illust/related with illust_id and filter', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v2/illust/related');
        expect(request.url.queryParameters['illust_id'], '42');
        expect(request.url.queryParameters['filter'], 'for_android');
        return _ok({'illusts': [], 'next_url': null});
      });
      final repo = await _repo(client);
      final page = await repo.fetchPage(42);
      expect(page.illusts, isEmpty);
      expect(page.nextUrl, isNull);
    });

    test('parses illusts and next_url', () async {
      final client = MockClient(
        (request) async => _ok({
          'illusts': [
            illustJson(901, pageCount: 1),
            illustJson(902, pageCount: 2, withMetaPages: true),
          ],
          'next_url': 'https://app-api.pixiv.net/v2/illust/related'
              '?illust_id=42&filter=for_ios&offset=2',
        }),
      );
      final repo = await _repo(client);
      final page = await repo.fetchPage(42);
      expect(page.illusts.map((e) => e.id), [901, 902]);
      expect(page.illusts[1].pageCount, 2);
      expect(page.nextUrl, contains('offset=2'));
    });

    test('malformed envelope raises ApiParseError', () async {
      final client = MockClient((request) async => _ok({'bogus': true}));
      final repo = await _repo(client);
      expect(
        () => repo.fetchPage(42),
        throwsA(
          isA<Object>().having(
            (e) => e.runtimeType.toString(),
            'type',
            'ApiParseError',
          ),
        ),
      );
    });
  });
}
