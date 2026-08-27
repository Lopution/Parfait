import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_client_identity.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const String _apiHost = 'app-api.pixiv.net';
const String _api = 'https://$_apiHost/v1/illust/recommended?offset=0';

class _CredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  Credential? seeded(String accountId) => _secrets[accountId];

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _MetadataRepository implements AccountMetadataRepository {
  _MetadataRepository(this.accounts, this.currentId);

  final List<Account> accounts;
  final String? currentId;

  @override
  Future<AccountMetadataSnapshot> load() async =>
      AccountMetadataSnapshot(accounts: accounts, currentId: currentId);

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

/// Mutable fixture shared between the transports and the assertions.
class _Fixture {
  _Fixture({
    this.rejectAll = false,
    this.rejectStaleSeed = false,
    this.refreshStatus = 200,
    this.apiDelay = Duration.zero,
    this.plain400 = false,
  });

  /// When true only the stale seeded token is rejected with 401.
  bool rejectStaleSeed;

  /// When true every request gets a 401 regardless of the token.
  bool rejectAll;

  /// Status code used to reject the stale token (401 or 400).
  int staleRejectionStatus = 401;

  /// When true a non-stale 400 carries an unrelated body (genuine
  /// parameter error) and must never trigger refresh.
  final bool plain400;

  int refreshStatus;
  Duration refreshDelay = Duration.zero;
  Duration apiDelay;

  final List<http.Request> apiRequests = [];
  var refreshCalls = 0;

  http.Client buildApiTransport() {
    return MockClient((request) async {
      apiRequests.add(request);
      if (apiDelay > Duration.zero) {
        await Future<void>.delayed(apiDelay);
      }
      final authorized = request.headers['Authorization'];
      final rejected = rejectAll ||
          (rejectStaleSeed && authorized == 'Bearer old-access');
      if (rejected) {
        final body = plain400
            ? '{"error":{"message":"Illust not found"}}'
            : '{"error":"invalid_grant"}';
        return http.Response(body, staleRejectionStatus);
      }
      return http.Response('{"ok":true}', 200);
    });
  }

  http.Client buildOauthTransport() {
    return MockClient((request) async {
      refreshCalls += 1;
      if (refreshDelay > Duration.zero) {
        await Future<void>.delayed(refreshDelay);
      }
      if (refreshStatus != 200) {
        return http.Response('{"error":"invalid_grant"}', refreshStatus);
      }
      return http.Response(
        jsonEncode({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'user': {'id': '100', 'name': 'user100'},
        }),
        200,
      );
    });
  }
}

Future<(ProviderContainer, PixivHttpClient, _CredentialStore, _Fixture)>
    _makeWorld({
  _Fixture? fixture,
  List<Account> accounts = const [
    Account(id: '100', userId: 100, name: 'user100'),
  ],
  String currentId = '100',
  Duration requestTimeout = PixivHttpClient.defaultRequestTimeout,
}) async {
  final f = fixture ?? _Fixture();
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();

  final credentials = _CredentialStore();
  credentials.seed(
    '100',
    const Credential(accessToken: 'old-access', refreshToken: 'old-refresh'),
  );

  final container = ProviderContainer(overrides: [
    credentialStoreProvider.overrideWithValue(credentials),
    accountMetadataRepositoryProvider.overrideWithValue(
      _MetadataRepository(accounts, currentId),
    ),
    oauthServiceProvider.overrideWithValue(
      OAuthService(client: f.buildOauthTransport()),
    ),
  ]);
  final store = container.read(accountStoreProvider.notifier);
  await container.read(accountStoreProvider.future);

  final client = PixivHttpClient(
    client: f.buildApiTransport(),
    accountStore: store,
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
    requestTimeout: requestTimeout,
  );
  return (container, client, credentials, f);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('requests carry centralized identity headers and bearer token',
      () async {
    final (container, client, _, fixture) = await _makeWorld();
    addTearDown(container.dispose);

    await client.getJson(Uri.parse(_api));

    final request = fixture.apiRequests.single;
    expect(request.headers['Authorization'], 'Bearer old-access');
    expect(request.headers['App-OS'], 'android');
    expect(request.headers['User-Agent'], PixivClientIdentity.userAgent);
    expect(request.headers['Accept-Language'], 'zh-CN');
  });

  test('20 concurrent requests with a stale token trigger one refresh',
      () async {
    final fixture = _Fixture();
    final (container, client, credentials, _) = await _makeWorld(
      fixture: fixture..rejectStaleSeed = true,
    );
    addTearDown(container.dispose);

    final results = await Future.wait([
      for (var i = 0; i < 20; i++)
        client
            .getJson(Uri.parse(_api))
            .then((_) => 'ok')
            .onError((_, _) => 'error'),
    ]);

    expect(results, everyElement('ok'));
    expect(fixture.refreshCalls, 1);
    expect(credentials.seeded('100')!.accessToken, 'new-access');
    expect(credentials.seeded('100')!.refreshToken, 'new-refresh');
  });

  test('a single request retries at most once on 401', () async {
    // Everything is rejected, even the refreshed token.
    final fixture = _Fixture(rejectAll: true);
    final (container, client, _, _) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiUnauthorized>()),
    );

    expect(fixture.apiRequests, hasLength(2));
    expect(fixture.refreshCalls, 1);
    expect(
      fixture.apiRequests.last.headers['Authorization'],
      'Bearer new-access',
    );
  });

  test('invalid refresh marks the account re-auth and terminates the queue',
      () async {
    final fixture = _Fixture(refreshStatus: 400, rejectStaleSeed: true);
    final (container, client, _, _) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiUnauthorized>()),
    );

    final state = container.read(accountStoreProvider).requireValue;
    expect(state.current!.authState, AccountAuthState.reauthRequired);

    // The next request fails with the same unified error class: no usable
    // session, no infinite loop, no second refresh attempt.
    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiUnauthorized>()),
    );
    expect(fixture.refreshCalls, 1);
  });

  test('400 invalid_grant triggers refresh and retries (live-device shape)',
      () async {
    // The recommended endpoint surfaces an expired token as a 400 with an
    // OAuth invalid_grant body instead of 401.
    final fixture = _Fixture(rejectStaleSeed: true)
      ..staleRejectionStatus = 400;
    final (container, client, _, fixtureF) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    final body = await client.getJson(Uri.parse(_api));
    expect(body['ok'], isTrue);
    expect(fixtureF.apiRequests, hasLength(2));
    expect(fixtureF.refreshCalls, 1);
    expect(
      fixtureF.apiRequests.last.headers['Authorization'],
      'Bearer new-access',
    );
  });

  test('plain 400 without invalid_grant never triggers refresh', () async {
    final fixture = _Fixture(rejectStaleSeed: true, plain400: true)
      ..staleRejectionStatus = 400;
    final (container, client, _, fixtureF) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiHttpError>()),
    );
    expect(fixtureF.apiRequests, hasLength(1));
    expect(fixtureF.refreshCalls, 0);
  });

  test('429 maps to rate limited with the retry-after hint', () async {
    final (container, _, _, _) = await _makeWorld();
    addTearDown(container.dispose);
    final rateLimited = PixivHttpClient(
      client: MockClient(
        (request) async =>
            http.Response('limited', 429, headers: {'retry-after': '7'}),
      ),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: _SeededCredentials(),
      oauthService: container.read(oauthServiceProvider),
    );

    await expectLater(
      rateLimited.getJson(Uri.parse(_api)),
      throwsA(isA<ApiRateLimited>()
          .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 7))),
    );
  });

  test('server errors map to ApiHttpError without retry', () async {
    final (container, _, _, _) = await _makeWorld();
    addTearDown(container.dispose);
    final failing = PixivHttpClient(
      client: MockClient((request) async => http.Response('boom', 500)),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: _SeededCredentials(),
      oauthService: container.read(oauthServiceProvider),
    );

    await expectLater(
      failing.getJson(Uri.parse(_api)),
      throwsA(isA<ApiHttpError>()
          .having((e) => e.statusCode, 'statusCode', 500)),
    );
  });

  test('non-JSON responses map to a parse error', () async {
    final (container, _, _, _) = await _makeWorld();
    addTearDown(container.dispose);
    final parseErrorClient = PixivHttpClient(
      client: MockClient(
        (request) async => http.Response('not json at all', 200),
      ),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: _SeededCredentials(),
      oauthService: container.read(oauthServiceProvider),
    );

    await expectLater(
      parseErrorClient.getJson(Uri.parse(_api)),
      throwsA(isA<ApiParseError>()),
    );
  });

  test('transport failures map to network errors and stay failures', () async {
    final (container, _, _, _) = await _makeWorld();
    addTearDown(container.dispose);
    final failing = PixivHttpClient(
      client: MockClient((request) async {
        throw http.ClientException('certificate verify failed');
      }),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: _SeededCredentials(),
      oauthService: container.read(oauthServiceProvider),
    );

    await expectLater(
      failing.getJson(Uri.parse(_api)),
      throwsA(isA<ApiNetworkError>()),
    );
  });

  test('slow responses time out with ApiTimeout', () async {
    final fixture = _Fixture(apiDelay: const Duration(seconds: 2));
    final (container, client, _, _) = await _makeWorld(
      fixture: fixture,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(container.dispose);

    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiTimeout>()),
    );
  });

  test('cancellation before send throws ApiCancelled', () async {
    final (container, client, _, _) = await _makeWorld();
    addTearDown(container.dispose);
    final token = CancelToken()..cancel();

    await expectLater(
      client.getJson(Uri.parse(_api), cancelToken: token),
      throwsA(isA<ApiCancelled>()),
    );
  });

  test('cancellation during an in-flight request surfaces ApiCancelled',
      () async {
    final (container, client, _, _) = await _makeWorld(
      fixture: _Fixture(apiDelay: const Duration(milliseconds: 500)),
    );
    addTearDown(container.dispose);
    final token = CancelToken();

    final request = client.getJson(Uri.parse(_api), cancelToken: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();

    await expectLater(request, throwsA(isA<ApiCancelled>()));
  });

  test('error objects never embed tokens or authorization material',
      () async {
    final fixture = _Fixture(refreshStatus: 400, rejectStaleSeed: true);
    final (container, client, _, _) = await _makeWorld(fixture: fixture);
    addTearDown(container.dispose);

    Object? caught;
    try {
      await client.getJson(Uri.parse(_api));
    } on ApiError catch (error) {
      caught = error;
    }
    expect(caught, isNotNull);
    final rendered = '$caught';
    expect(rendered.contains('old-access'), isFalse);
    expect(rendered.contains('new-access'), isFalse);
    expect(rendered.contains('old-refresh'), isFalse);
    expect(rendered.contains('Bearer'), isFalse);
  });
}

class _SeededCredentials implements CredentialStore {
  final _delegate = _CredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'old-access', refreshToken: 'old-refresh'),
    );

  @override
  Future<Credential?> read(String accountId) => _delegate.read(accountId);

  @override
  Future<void> write(String accountId, Credential credential) =>
      _delegate.write(accountId, credential);

  @override
  Future<void> delete(String accountId) => _delegate.delete(accountId);
}
