import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/pixiv_client_identity.dart';
import 'package:parfait/core/network/data_worker.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/fake_settings.dart';

const String _apiHost = 'app-api.pixiv.net';
const String _api = 'https://$_apiHost/v1/illust/recommended?offset=0';
const _avatar = 'https://i.pximg.net/170.jpg';

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

  /// When true the token endpoint is unreachable (connection-level failure).
  bool refreshUnreachable = false;

  /// The avatar the token response's user carries, in pixiv's shape; null
  /// leaves `profile_image_urls` out.
  String? refreshAvatar = _avatar;

  final List<http.Request> apiRequests = [];
  var refreshCalls = 0;

  /// Holds the first API request until completed; [arrived] says it came.
  Completer<void>? holdFirst;
  final arrived = Completer<void>();

  http.Client buildApiTransport() {
    return MockClient((request) async {
      apiRequests.add(request);
      if (apiRequests.length == 1 && holdFirst != null) {
        arrived.complete();
        await holdFirst!.future;
      }
      if (apiDelay > Duration.zero) {
        await Future<void>.delayed(apiDelay);
      }
      final authorized = request.headers['Authorization'];
      final rejected =
          rejectAll || (rejectStaleSeed && authorized == 'Bearer old-access');
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
      if (refreshUnreachable) {
        throw http.ClientException('connection reset', request.url);
      }
      if (refreshStatus != 200) {
        return http.Response('{"error":"invalid_grant"}', refreshStatus);
      }
      return http.Response(
        jsonEncode({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'user': {
            'id': '100',
            'name': 'user100',
            if (refreshAvatar case final avatar?)
              'profile_image_urls': {
                'px_16x16': 'https://i.pximg.net/16.jpg',
                'px_50x50': 'https://i.pximg.net/50.jpg',
                'px_170x170': avatar,
              },
          },
        }),
        200,
      );
    });
  }
}

Future<(ProviderContainer, PixivHttpClient, FakeCredentialStore, _Fixture)>
_makeWorld({
  _Fixture? fixture,
  List<Account> accounts = const [
    Account(id: '100', userId: 100, name: 'user100'),
  ],
  String currentId = '100',
  Map<String, Credential> moreCredentials = const {},
  Duration requestTimeout = PixivHttpClient.defaultRequestTimeout,
  String languageTag = 'zh-CN',
}) async {
  final f = fixture ?? _Fixture();
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();

  final credentials = FakeCredentialStore(
    values: {
      '100': const Credential(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      ),
      ...moreCredentials,
    },
  );

  await seedAccounts(accounts, currentId: currentId);
  final container = ProviderContainer.test(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      oauthServiceProvider.overrideWithValue(
        OAuthService(client: f.buildOauthTransport()),
      ),
    ],
  );
  final store = container.read(accountStoreProvider.notifier);
  await container.read(accountStoreProvider.future);

  final client = PixivHttpClient(
    client: f.buildApiTransport(),
    accountStore: store,
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
    languageTag: languageTag,
    requestTimeout: requestTimeout,
  );
  return (container, client, credentials, f);
}

/// A client over [transport] for the world's account, as a test that needs
/// its own transport builds one.
PixivHttpClient _clientOver(
  ProviderContainer container,
  http.Client transport, {
  DataWorker dataWorker = const InlineDataWorker(),
}) => PixivHttpClient(
  client: transport,
  accountStore: container.read(accountStoreProvider.notifier),
  credentialStore: FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'old-access', refreshToken: 'old-refresh'),
    },
  ),
  oauthService: container.read(oauthServiceProvider),
  dataWorker: dataWorker,
);

/// Cancels [token] as the parse starts: the response is in, the parse is
/// not.
class _CancelOnParse implements DataWorker {
  _CancelOnParse(this.token);

  final CancelToken token;

  @override
  Future<R> run<I, R>(
    R Function(I input) task,
    I input, {
    required String label,
  }) {
    token.cancel();
    return const InlineDataWorker().run(task, input, label: label);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'requests carry centralized identity headers and bearer token',
    () async {
      final (container, client, _, fixture) = await _makeWorld(
        languageTag: 'ja',
      );

      await client.getJson(Uri.parse(_api));

      final request = fixture.apiRequests.single;
      expect(request.headers['Authorization'], 'Bearer old-access');
      expect(request.headers['App-OS'], 'android');
      expect(request.headers['User-Agent'], PixivClientIdentity.userAgent);
      expect(request.headers['Accept-Language'], 'ja');
    },
  );

  test('pixivHttpClientProvider follows settings.languageTag (R6)', () async {
    final repository = FakeSettingsRepository(
      const AppSettings(
        guideCompleted: true,
        languageTag: 'ja',
        themeCode: AppSettings.systemTheme,
      ),
    );
    final credentials = FakeCredentialStore();
    final container = ProviderContainer.test(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repository),
        credentialStoreProvider.overrideWithValue(credentials),
        // No sockets: the policy hands out a canned transport.
        pixivNetworkFactoryProvider.overrideWithValue(
          PixivNetworkFactory(
            NetworkAccessPolicy(
              clientFactory: (route, host, purpose) =>
                  MockClient((_) async => http.Response('{}', 200)),
            ),
          ),
        ),
      ],
    );
    await container.read(settingsProvider.future);

    expect(container.read(pixivHttpClientProvider).languageTag, 'ja');

    await container.read(settingsProvider.notifier).selectLanguage('en-US');

    // The provider watches `settings.languageTag`, so the client is rebuilt.
    expect(container.read(pixivHttpClientProvider).languageTag, 'en-US');
  });

  test(
    'pre-import verification can use a supplied token without switching stores',
    () async {
      final (container, client, credentials, fixture) = await _makeWorld();

      await client.getJsonWithCredential(
        Uri.parse(_api),
        credential: const Credential(
          accessToken: 'imported-access',
          refreshToken: 'imported-refresh',
        ),
      );

      expect(
        fixture.apiRequests.single.headers['Authorization'],
        'Bearer imported-access',
      );
      expect(credentials.values['100']!.accessToken, 'old-access');
      expect(credentials.values['100']!.refreshToken, 'old-refresh');
    },
  );

  test('pre-import verification rejects a non-App-API destination', () async {
    final (container, client, _, fixture) = await _makeWorld();

    await expectLater(
      client.getJsonWithCredential(
        Uri.parse('https://evil.example/v1/user/detail'),
        credential: const Credential(
          accessToken: 'imported-access',
          refreshToken: 'imported-refresh',
        ),
      ),
      throwsA(isA<PixivDestinationException>()),
    );
    expect(fixture.apiRequests, isEmpty);
  });

  test(
    'pre-import verification maps 400 invalid_grant without refreshing',
    () async {
      final fixture = _Fixture(rejectStaleSeed: true)
        ..staleRejectionStatus = 400;
      final (container, client, _, fixtureF) = await _makeWorld(
        fixture: fixture,
      );

      await expectLater(
        client.getJsonWithCredential(
          Uri.parse(_api),
          credential: const Credential(
            accessToken: 'old-access',
            refreshToken: 'imported-refresh',
          ),
        ),
        throwsA(isA<ApiUnauthorized>()),
      );
      expect(fixtureF.apiRequests, hasLength(1));
      expect(fixtureF.refreshCalls, 0);
    },
  );

  test(
    '20 concurrent requests with a stale token trigger one refresh',
    () async {
      final fixture = _Fixture();
      final (container, client, credentials, _) = await _makeWorld(
        fixture: fixture..rejectStaleSeed = true,
      );

      final results = await Future.wait([
        for (var i = 0; i < 20; i++)
          client
              .getJson(Uri.parse(_api))
              .then((_) => 'ok')
              .onError((_, _) => 'error'),
      ]);

      expect(results, everyElement('ok'));
      expect(fixture.refreshCalls, 1);
      expect(credentials.values['100']!.accessToken, 'new-access');
      expect(credentials.values['100']!.refreshToken, 'new-refresh');
    },
  );

  test('concurrent identical GETs share one transport flight', () async {
    final fixture = _Fixture(apiDelay: const Duration(milliseconds: 20));
    final (container, client, _, fixtureF) = await _makeWorld(fixture: fixture);

    await Future.wait([
      client.getJson(Uri.parse(_api)),
      client.getJson(Uri.parse(_api)),
    ]);

    expect(fixtureF.apiRequests, hasLength(1));
  });

  test('a single request retries at most once on 401', () async {
    // Everything is rejected, even the refreshed token.
    final fixture = _Fixture(rejectAll: true);
    final (container, client, _, _) = await _makeWorld(fixture: fixture);

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

  test(
    'a refresh fills in the account avatar, or keeps the stored one',
    () async {
      for (final (sent, stored) in [
        (_avatar, null),
        (null, 'https://i.pximg.net/old.jpg'),
      ]) {
        final fixture = _Fixture(rejectStaleSeed: true)..refreshAvatar = sent;
        final (container, client, _, _) = await _makeWorld(
          fixture: fixture,
          accounts: [
            Account(
              id: '100',
              userId: 100,
              name: 'user100',
              profileImageUrl: stored,
            ),
          ],
        );

        await client.getJson(Uri.parse(_api));

        expect(fixture.refreshCalls, 1);
        expect(
          container
              .read(accountStoreProvider)
              .requireValue
              .current!
              .profileImageUrl,
          sent ?? stored,
          reason: 'sent $sent',
        );
      }
    },
  );

  test(
    'invalid refresh marks the account re-auth and terminates the queue',
    () async {
      final fixture = _Fixture(refreshStatus: 400, rejectStaleSeed: true);
      final (container, client, _, _) = await _makeWorld(fixture: fixture);

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
    },
  );

  // Only the token endpoint rejecting the refresh token ends the session. A
  // refresh that could not complete (server error, rate limit, network) is a
  // failed request: the account stays signed in and the next request
  // refreshes again.
  test(
    'a refresh that could not complete keeps the account signed in',
    () async {
      for (final (label, fail, error) in [
        (
          'server error',
          (_Fixture f) => f.refreshStatus = 503,
          isA<ApiHttpError>(),
        ),
        (
          'rate limit',
          (_Fixture f) => f.refreshStatus = 429,
          isA<ApiRateLimited>(),
        ),
        (
          'unreachable',
          (_Fixture f) => f.refreshUnreachable = true,
          isA<ApiNetworkError>(),
        ),
      ]) {
        final fixture = _Fixture(rejectStaleSeed: true);
        fail(fixture);
        final (container, client, _, _) = await _makeWorld(fixture: fixture);

        await expectLater(
          client.getJson(Uri.parse(_api)),
          throwsA(error),
          reason: label,
        );
        expect(
          container.read(accountStoreProvider).requireValue.current!.authState,
          AccountAuthState.authenticated,
          reason: label,
        );

        fixture
          ..refreshStatus = 200
          ..refreshUnreachable = false;
        expect(await client.getJson(Uri.parse(_api)), {
          'ok': true,
        }, reason: label);
        expect(fixture.refreshCalls, 2, reason: label);
      }
    },
  );

  test(
    '400 invalid_grant triggers refresh and retries (live-device shape)',
    () async {
      // The recommended endpoint surfaces an expired token as a 400 with an
      // OAuth invalid_grant body instead of 401.
      final fixture = _Fixture(rejectStaleSeed: true)
        ..staleRejectionStatus = 400;
      final (container, client, _, fixtureF) = await _makeWorld(
        fixture: fixture,
      );

      final body = await client.getJson(Uri.parse(_api));
      expect(body['ok'], isTrue);
      expect(fixtureF.apiRequests, hasLength(2));
      expect(fixtureF.refreshCalls, 1);
      expect(
        fixtureF.apiRequests.last.headers['Authorization'],
        'Bearer new-access',
      );
    },
  );

  test(
    'non-idempotent POST refreshes once but never replays its body',
    () async {
      final fixture = _Fixture(rejectStaleSeed: true);
      final (container, client, _, fixtureF) = await _makeWorld(
        fixture: fixture,
      );

      await expectLater(
        client.post(
          Uri.parse('https://$_apiHost/v1/illust/comment/add'),
          body: {'illust_id': '42', 'comment': 'one-shot'},
          allowAuthReplay: false,
        ),
        throwsA(isA<ApiUnauthorized>()),
      );

      expect(fixtureF.apiRequests, hasLength(1));
      expect(fixtureF.apiRequests.single.method, 'POST');
      expect(fixtureF.refreshCalls, 1);
    },
  );

  test(
    'opt-in POST refreshes once and replays the original body exactly once',
    () async {
      // C2: bookmark/follow/comment repositories pass allowAuthReplay: true.
      // An explicit 401 may refresh and resend the original mutation once.
      final fixture = _Fixture(rejectStaleSeed: true);
      final (container, client, _, fixtureF) = await _makeWorld(
        fixture: fixture,
      );

      final response = await client.post(
        Uri.parse('https://$_apiHost/v2/illust/bookmark/add'),
        body: const {'illust_id': '42', 'restrict': 'public'},
        allowAuthReplay: true,
      );

      expect(response.statusCode, 200);
      expect(fixtureF.refreshCalls, 1);
      expect(fixtureF.apiRequests, hasLength(2));
      expect(fixtureF.apiRequests.map((request) => request.method), [
        'POST',
        'POST',
      ]);
      expect(
        fixtureF.apiRequests.first.headers['Authorization'],
        'Bearer old-access',
      );
      expect(
        fixtureF.apiRequests.last.headers['Authorization'],
        'Bearer new-access',
      );
      expect(fixtureF.apiRequests.last.bodyFields['illust_id'], '42');
      expect(fixtureF.apiRequests.last.bodyFields['restrict'], 'public');
    },
  );

  test(
    'a request keeps its account through a switch, its refresh too',
    () async {
      final fixture = _Fixture(rejectStaleSeed: true)..holdFirst = Completer();
      final (container, client, credentials, _) = await _makeWorld(
        fixture: fixture,
        accounts: const [
          Account(id: '100', userId: 100, name: 'user100'),
          Account(id: '200', userId: 200, name: 'user200'),
        ],
        moreCredentials: const {
          '200': Credential(accessToken: 'b-access', refreshToken: 'b-refresh'),
        },
      );

      final bookmark = client.post(
        Uri.parse('https://$_apiHost/v2/illust/bookmark/add'),
        body: const {'illust_id': '42', 'restrict': 'public'},
        allowAuthReplay: true,
      );
      await fixture.arrived.future;
      await container.read(accountStoreProvider.notifier).switchAccount('200');
      fixture.holdFirst!.complete();

      expect((await bookmark).statusCode, 200);
      // Account 100's bookmark, sent and replayed with 100's tokens only.
      expect(fixture.apiRequests.map((r) => r.headers['Authorization']), [
        'Bearer old-access',
        'Bearer new-access',
      ]);
      expect((await credentials.read('100'))!.accessToken, 'new-access');
      expect((await credentials.read('200'))!.accessToken, 'b-access');
      // The refresh saved 100's tokens without taking the user back to 100.
      expect(
        container.read(accountStoreProvider).requireValue.currentId,
        '200',
      );
    },
  );

  test('opt-in POST surfaces a second 401 without another replay', () async {
    // maxRetries = 1: refresh + one replay, then the second 401 is final.
    final fixture = _Fixture(rejectAll: true);
    final (container, client, _, fixtureF) = await _makeWorld(fixture: fixture);

    await expectLater(
      client.post(
        Uri.parse('https://$_apiHost/v2/illust/bookmark/add'),
        body: const {'illust_id': '42', 'restrict': 'public'},
        allowAuthReplay: true,
      ),
      throwsA(isA<ApiUnauthorized>()),
    );

    expect(PixivHttpClient.maxRetries, 1);
    expect(fixtureF.refreshCalls, 1);
    expect(fixtureF.apiRequests, hasLength(2));
    expect(
      fixtureF.apiRequests.last.headers['Authorization'],
      'Bearer new-access',
    );
  });

  test('plain 400 without invalid_grant never triggers refresh', () async {
    final fixture = _Fixture(rejectStaleSeed: true, plain400: true)
      ..staleRejectionStatus = 400;
    final (container, client, _, fixtureF) = await _makeWorld(fixture: fixture);

    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiHttpError>()),
    );
    expect(fixtureF.apiRequests, hasLength(1));
    expect(fixtureF.refreshCalls, 0);
  });

  test(
    '429, server, parse and transport failures map to errors, no retry',
    () async {
      final (container, _, _, _) = await _makeWorld();
      for (final (name, respond, error) in [
        (
          '429',
          () => http.Response('limited', 429, headers: {'retry-after': '7'}),
          isA<ApiRateLimited>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 7),
          ),
        ),
        (
          '500',
          () => http.Response('boom', 500),
          isA<ApiHttpError>().having((e) => e.statusCode, 'statusCode', 500),
        ),
        (
          'not JSON',
          () => http.Response('not json at all', 200),
          isA<ApiParseError>(),
        ),
        (
          'transport',
          () => throw http.ClientException('certificate verify failed'),
          isA<ApiNetworkError>(),
        ),
      ]) {
        var requests = 0;
        final client = _clientOver(
          container,
          MockClient((request) async {
            requests += 1;
            return respond();
          }),
        );

        await expectLater(
          client.getJson(Uri.parse(_api)),
          throwsA(error),
          reason: name,
        );
        expect(requests, 1, reason: name);
      }
    },
  );

  test('after a 429 reads wait out the cooldown; posts still go', () async {
    var now = DateTime(2026, 10, 8, 12);
    await withClock(Clock(() => now), () async {
      final (container, _, _, _) = await _makeWorld();
      var limited = true;
      final requests = <String>[];
      final client = _clientOver(
        container,
        MockClient((request) async {
          requests.add(request.method);
          return limited
              ? http.Response('limited', 429)
              : http.Response('{}', 200);
        }),
      );

      await expectLater(
        client.getJson(Uri.parse(_api)),
        throwsA(isA<ApiRateLimited>()),
      );
      limited = false;
      now = now.add(const Duration(seconds: 4));
      await expectLater(
        client.getJson(Uri.parse(_api)),
        throwsA(
          isA<ApiRateLimited>().having(
            (e) => e.retryAfter,
            'retryAfter',
            PixivHttpClient.rateLimitCooldown - const Duration(seconds: 4),
          ),
        ),
      );
      await client.post(Uri.parse(_api));
      expect(requests, ['GET', 'POST']);

      now = now.add(PixivHttpClient.rateLimitCooldown);
      await client.getJson(Uri.parse(_api));
      expect(requests, ['GET', 'POST', 'GET']);
    });
  });

  test('bodies decode and map on the data worker unchanged', () async {
    final (container, _, _, _) = await _makeWorld();
    final worker = IsolateDataWorker();
    addTearDown(worker.close);
    PixivHttpClient clientReturning(String body) => _clientOver(
      container,
      MockClient(
        (request) async => http.Response.bytes(utf8.encode(body), 200),
      ),
      dataWorker: worker,
    );
    final illusts = [
      for (var i = 0; i < 1000; i++) {'id': i, 'title': '作品 $i' * 4},
    ];
    final body = jsonEncode({'illusts': illusts, 'next_url': null});
    final json = await clientReturning(body).getJson(Uri.parse(_api));
    expect(json['illusts'], illusts);
    expect(json.containsKey('next_url'), isTrue);

    // A malformed large body keeps the parse-error contract across the
    // isolate boundary.
    await expectLater(
      clientReturning(
        '${body.substring(0, body.length - 1)},',
      ).getJson(Uri.parse(_api)),
      throwsA(isA<ApiParseError>()),
    );
    // So does a well-formed body that is not an object.
    await expectLater(
      clientReturning(jsonEncode(illusts)).getJson(Uri.parse(_api)),
      throwsA(isA<ApiParseError>()),
    );
  });

  test('slow responses time out with ApiTimeout', () async {
    final fixture = _Fixture(apiDelay: const Duration(seconds: 2));
    final (container, client, _, _) = await _makeWorld(
      fixture: fixture,
      requestTimeout: const Duration(milliseconds: 30),
    );

    await expectLater(
      client.getJson(Uri.parse(_api)),
      throwsA(isA<ApiTimeout>()),
    );
  });

  test('cancellation before send throws ApiCancelled', () async {
    final (container, client, _, _) = await _makeWorld();
    final token = CancelToken()..cancel();

    await expectLater(
      client.getJson(Uri.parse(_api), cancelToken: token),
      throwsA(isA<ApiCancelled>()),
    );
  });

  test(
    'cancellation in flight or during the parse surfaces ApiCancelled',
    () async {
      final (container, client, _, _) = await _makeWorld(
        fixture: _Fixture(apiDelay: const Duration(milliseconds: 500)),
      );
      final token = CancelToken();

      final request = client.getJson(Uri.parse(_api), cancelToken: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();

      await expectLater(request, throwsA(isA<ApiCancelled>()));

      // The response is in and its page closes while the body parses: the
      // request ends cancelled, a malformed body too.
      for (final body in ['{}', '{']) {
        final parsing = CancelToken();
        final parsed = _clientOver(
          container,
          MockClient((_) async => http.Response(body, 200)),
          dataWorker: _CancelOnParse(parsing),
        ).getJson(Uri.parse(_api), cancelToken: parsing);
        await expectLater(parsed, throwsA(isA<ApiCancelled>()), reason: body);
      }
    },
  );

  test('error objects never embed tokens or authorization material', () async {
    final fixture = _Fixture(refreshStatus: 400, rejectStaleSeed: true);
    final (container, client, _, _) = await _makeWorld(fixture: fixture);

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
