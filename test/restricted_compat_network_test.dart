import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/download/download_transport.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/network_providers.dart';
import 'package:pixiv_func/core/network/compat/policy_download_transport.dart';
import 'package:pixiv_func/core/network/compat/secure_resolver.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient({this.failure, this.statusCode = 200, this.body = '{}'});

  final Object? failure;
  final int statusCode;
  final String body;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final failure = this.failure;
    if (failure != null) throw failure;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
      request: request,
    );
  }
}

class _FakeResolver implements SecureResolver {
  _FakeResolver(this.addresses);

  final List<InternetAddress> addresses;
  var calls = 0;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    calls++;
    return ResolvedHost(
      host: host,
      addresses: addresses,
      dnsSource: DnsSource.system,
      revision: revision,
      ttl: const Duration(seconds: 30),
    );
  }

  @override
  Future<void> dispose() async {}
}

class _FakeEchResolver extends _FakeResolver implements EchConfigResolver {
  _FakeEchResolver(
    super.addresses, {
    this.frontAddresses = const [],
    this.ttl = const Duration(seconds: 30),
  });

  final List<InternetAddress> frontAddresses;
  final Duration ttl;
  var echCalls = 0;

  @override
  Future<EchConfigResult> lookupEchConfig(
    String frontHost, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    echCalls++;
    return EchConfigResult(
      echConfig: Uint8List.fromList(const [1, 2, 3, 4]),
      ttl: ttl,
      frontAddresses: frontAddresses,
    );
  }
}

class _GateFailureClient extends http.BaseClient {
  final gate = Completer<void>();
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await gate.future;
    throw SocketException('Connection refused');
  }
}

class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.outcomes);

  final List<Object?> outcomes;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (outcomes.isEmpty) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{}')),
        200,
        request: request,
      );
    }
    final outcome = outcomes.removeAt(0);
    if (outcome is Object && outcome is! http.StreamedResponse) {
      throw outcome;
    }
    return outcome as http.StreamedResponse? ??
        http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{}')),
          200,
          request: request,
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'destination registry accepts only canonical Pixiv hosts and purposes',
    () {
      final registry = PixivDestinationRegistry();

      expect(
        registry
            .require(
              Uri.parse('https://app-api.pixiv.net/v1/illust/recommended'),
              PixivDestinationPurpose.appApi,
            )
            .canonicalHost,
        'app-api.pixiv.net',
      );
      expect(
        registry
            .require(
              Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
              PixivDestinationPurpose.oauth,
            )
            .canonicalHost,
        'oauth.secure.pixiv.net',
      );
      expect(
        registry
            .require(
              Uri.parse('https://accounts.pixiv.net/signup'),
              PixivDestinationPurpose.accountsWeb,
            )
            .canonicalHost,
        'accounts.pixiv.net',
      );

      final rejected = <Uri>[
        Uri.parse('https://evil.pixiv.net/v1/illust/recommended'),
        Uri.parse(
          'https://app-api.pixiv.net.evil.example/v1/illust/recommended',
        ),
        Uri.parse('https://app-api.pixiv.net./v1/illust/recommended'),
        Uri.parse('https://127.0.0.1/v1/illust/recommended'),
        Uri.parse('https://app-api.pixiv.net:8443/v1/illust/recommended'),
        Uri.parse('http://app-api.pixiv.net/v1/illust/recommended'),
        Uri.parse('https://user:pass@app-api.pixiv.net/v1/illust/recommended'),
        Uri.parse('https://app-api.pixiv.net/v1/illust/recommended#token'),
      ];
      for (final uri in rejected) {
        expect(
          () => registry.require(uri, PixivDestinationPurpose.appApi),
          throwsA(isA<PixivDestinationException>()),
          reason: uri.toString(),
        );
      }
      expect(
        () => registry.require(
          Uri.parse('https://app-api.pixiv.net/auth/token'),
          PixivDestinationPurpose.oauth,
        ),
        throwsA(isA<PixivDestinationException>()),
      );
    },
  );

  test('route pool keys distinguish ECH rotations and canonical hosts', () {
    final revision = const NetworkRevision(0);
    final address = InternetAddress('1.2.3.30');
    final first = NetworkRoute.ech(revision, address, [1, 2, 3]);
    final second = NetworkRoute.ech(revision, address, [1, 2, 4]);
    expect(first.key, isNot(second.key));

    final clients = <http.Client>[];
    final policy = NetworkAccessPolicy(
      clientFactory: (_, _, _) {
        final client = _FakeClient();
        clients.add(client);
        return client;
      },
    );
    addTearDown(policy.dispose);
    final firstClient = policy.clientFor(
      PixivDestinationPurpose.appApi,
      first,
      'app-api.pixiv.net',
    );
    final secondClient = policy.clientFor(
      PixivDestinationPurpose.appApi,
      first,
      'oauth.secure.pixiv.net',
    );
    expect(firstClient, isNot(same(secondClient)));
    expect(clients, hasLength(2));
  });

  test(
    'transport classifier keeps security and protocol failures terminal',
    () {
      expect(
        TransportFailureClassifier.classify(
          SocketException('Failed host lookup: app-api.pixiv.net'),
        ).kind,
        NetworkFailureKind.dns,
      );
      expect(
        TransportFailureClassifier.classify(
          SocketException('Connection refused'),
        ).kind,
        NetworkFailureKind.connect,
      );
      // dart:io's generic HandshakeException is not proof of certificate
      // replacement; a reset can carry the same text. Only rhttp's
      // structured invalid-certificate error is terminal.
      expect(
        TransportFailureClassifier.classify(
          HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ).kind,
        NetworkFailureKind.tlsHandshake,
      );
      expect(
        TransportFailureClassifier.classify(
          NetworkFailureException(NetworkFailureKind.cancelled),
        ).kind,
        NetworkFailureKind.cancelled,
      );
      expect(
        TransportFailureClassifier.isFallbackEligible(
          SocketException('Connection reset by peer'),
        ),
        isTrue,
      );
      // Handshake reset injected mid-handshake (GFW RST): no cert/hostname
      // keywords, so it classifies tlsHandshake and MAY fall back to the
      // strict DoH tier.
      expect(
        TransportFailureClassifier.classify(
          HandshakeException('Connection closed during handshake'),
        ).kind,
        NetworkFailureKind.tlsHandshake,
      );
      expect(
        TransportFailureClassifier.isFallbackEligible(
          HandshakeException('Connection closed during handshake'),
        ),
        isTrue,
      );
      expect(
        TransportFailureClassifier.isFallbackEligible(
          HandshakeException('certificate mismatch'),
        ),
        isTrue,
      );
      expect(
        TransportFailureClassifier.isFallbackEligible(
          NetworkFailureException(NetworkFailureKind.auth),
        ),
        isFalse,
      );
    },
  );

  test('rhttp structured exceptions map without textual security guesses', () {
    final request = rhttp.HttpRequest(
      method: rhttp.HttpMethod.get,
      url: 'https://app-api.pixiv.net/v1/illust/prime',
    );
    expect(
      TransportFailureClassifier.classify(
        rhttp.RhttpWrappedClientException(
          'ignored',
          Uri.parse(request.url),
          rhttp.RhttpInvalidCertificateException(
            request: request,
            message: 'hostname mismatch',
          ),
        ),
      ).kind,
      NetworkFailureKind.certificateMismatch,
    );
    expect(
      TransportFailureClassifier.classify(
        rhttp.RhttpWrappedClientException(
          'ignored',
          Uri.parse(request.url),
          rhttp.RhttpTimeoutException(request),
        ),
      ).kind,
      NetworkFailureKind.timeout,
    );
    expect(
      TransportFailureClassifier.classify(
        rhttp.RhttpWrappedClientException(
          'ignored',
          Uri.parse(request.url),
          rhttp.RhttpConnectionException(request, 'handshake reset'),
        ),
      ).kind,
      NetworkFailureKind.reset,
    );
    expect(
      TransportFailureClassifier.classify(
        rhttp.RhttpWrappedClientException(
          'ignored',
          Uri.parse(request.url),
          rhttp.RhttpCancelException(request),
        ),
      ).kind,
      NetworkFailureKind.cancelled,
    );
  });

  test('automatic mode falls back only for a safe empty GET', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: '{"route":"secure-dns"}');
    final resolver = _FakeResolver([InternetAddress('1.2.3.4')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    final response = await client.get(
      Uri.parse('https://app-api.pixiv.net/v1/illust/recommended'),
    );

    expect(response.statusCode, 200);
    expect(resolver.calls, 1);
    expect(direct.requests, hasLength(1));
    expect(direct.requests.single.method, 'HEAD');
    expect(secureDns.requests, hasLength(2));
    expect(secureDns.requests.first.method, 'HEAD');
    expect(secureDns.requests.last.method, 'GET');
    expect(secureDns.requests.last.url.host, 'app-api.pixiv.net');
    expect(secureDns.requests.last.url.port, 443);
  });

  test('an already reachable network keeps the direct route', () async {
    final direct = _FakeClient(body: '{"route":"direct"}');
    final resolver = _FakeResolver([InternetAddress('1.2.3.40')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, purpose) => direct,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    final response = await client.get(_apiUri);

    expect(response.statusCode, 200);
    expect(resolver.calls, 0, reason: 'direct success needs no strict DNS');
    expect(direct.requests.map((request) => request.method), ['HEAD', 'GET']);
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isFalse);
  });

  test('route probe selects strict route before a POST body is sent', () async {
    final direct = _FakeClient(failure: SocketException('Connection reset'));
    final secureDns = _FakeClient(body: 'should-not-send');
    final resolver = _FakeResolver([InternetAddress('1.2.3.5')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    final response = await client.post(
      Uri.parse('https://app-api.pixiv.net/v1/illust/bookmark/add'),
      body: const {'illust_id': '1'},
    );
    expect(response.statusCode, 200);
    expect(resolver.calls, 1);
    expect(direct.requests, hasLength(1));
    expect(direct.requests.single.method, 'HEAD');
    expect(secureDns.requests, hasLength(2));
    expect(secureDns.requests.map((request) => request.method), [
      'HEAD',
      'POST',
    ]);
  });

  test('a non-idempotent business failure is never replayed', () async {
    final direct = _ScriptedClient([
      null, // side-effect-free route probe succeeds
      SocketException('connection reset after POST'),
    ]);
    final fallback = _FakeClient(body: 'must-not-send');
    final resolver = _FakeEchResolver(
      [InternetAddress('1.2.3.41')],
      frontAddresses: [InternetAddress('1.2.3.42')],
    );
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, purpose) =>
          route.kind == NetworkRouteKind.direct ? direct : fallback,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    await expectLater(
      client.post(
        Uri.parse('https://app-api.pixiv.net/v1/illust/bookmark/add'),
        body: const {'illust_id': '99'},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(direct.requests.map((request) => request.method), ['HEAD', 'POST']);
    expect(
      fallback.requests,
      isEmpty,
      reason: 'a failed POST cannot trigger a second route or POST replay',
    );
    expect(resolver.echCalls, 0);
  });

  test('unknown network selects ECH before sending a mutation', () async {
    final direct = _FakeClient(failure: SocketException('Connection reset'));
    final ech = _FakeClient(body: '{"route":"ech"}');
    final doh = _FakeClient(body: '{"route":"doh"}');
    final resolver = _FakeEchResolver(
      [InternetAddress('1.2.3.20')],
      frontAddresses: [InternetAddress('1.2.3.21')],
    );
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, _) => switch (route.kind) {
        NetworkRouteKind.direct => direct,
        NetworkRouteKind.ech => ech,
        _ => doh,
      },
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    final response = await client.post(
      Uri.parse('https://app-api.pixiv.net/v1/illust/bookmark/add'),
      body: const {'illust_id': '42'},
    );

    expect(response.statusCode, 200);
    expect(resolver.echCalls, 1);
    expect(direct.requests.map((request) => request.method), ['HEAD']);
    expect(ech.requests.map((request) => request.method), ['HEAD', 'POST']);
    expect(
      doh.requests,
      isEmpty,
      reason: 'a successful ECH probe must prevent lower tiers',
    );
  });

  test('remembered ECH is reused and refreshed instead of removed', () async {
    final base = DateTime(2026, 8, 31, 12);
    var now = base;
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final ech = _FakeClient(body: '{"route":"ech"}');
    final resolver = _FakeEchResolver(
      [InternetAddress('1.2.3.22')],
      frontAddresses: [InternetAddress('1.2.3.23')],
      ttl: const Duration(seconds: 30),
    );
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clock: () => now,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : ech,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    await client.get(_apiUri);
    expect(
      policy.rememberedRouteKind('app-api.pixiv.net'),
      NetworkRouteKind.ech,
    );
    expect(direct.requests, hasLength(1));
    expect(ech.requests, hasLength(2));

    now = base.add(const Duration(seconds: 20));
    await client.get(_apiUri);
    expect(
      policy.rememberedRouteKind('app-api.pixiv.net'),
      NetworkRouteKind.ech,
    );
    expect(
      direct.requests,
      hasLength(1),
      reason: 'remembered ECH skips direct',
    );
    expect(
      ech.requests,
      hasLength(3),
      reason: 'business request uses ECH once',
    );

    // 25 seconds after the refresh is still within the 30-second DNS TTL;
    // without refreshing on the second success it would already be stale.
    now = base.add(const Duration(seconds: 45));
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);
  });

  test(
    'failed remembered route is invalidated without repeating its tier',
    () async {
      final direct = _FakeClient(
        failure: SocketException('Connection refused'),
      );
      final ech = _ScriptedClient([
        null, // independent ECH probe succeeds
        SocketException('Connection reset'), // selected GET fails
      ]);
      final doh = _FakeClient(body: '{"route":"doh"}');
      final resolver = _FakeEchResolver(
        [InternetAddress('1.2.3.24')],
        frontAddresses: [InternetAddress('1.2.3.25')],
      );
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) => switch (route.kind) {
          NetworkRouteKind.direct => direct,
          NetworkRouteKind.ech => ech,
          _ => doh,
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );

      final response = await client.get(_apiUri);
      expect(response.statusCode, 200);
      expect(ech.requests.map((request) => request.method), [
        'HEAD',
        'GET',
      ], reason: 'the failed ECH route is not probed or sent again');
      expect(doh.requests.map((request) => request.method), ['HEAD', 'GET']);
      expect(
        policy.rememberedRouteKind('app-api.pixiv.net'),
        NetworkRouteKind.dohRealSni,
      );
    },
  );

  test(
    'HTTP, auth, certificate and cancellation responses do not fallback',
    () async {
      final resolver = _FakeResolver([InternetAddress('1.2.3.6')]);
      for (final failure in <Object>[
        NetworkFailureException(NetworkFailureKind.certificateMismatch),
        NetworkFailureException(NetworkFailureKind.auth),
        NetworkFailureException(NetworkFailureKind.cancelled),
      ]) {
        final direct = _FakeClient(failure: failure);
        final secureDns = _FakeClient();
        final policy = NetworkAccessPolicy(
          resolver: resolver,
          clientFactory: (route, canonicalHost, _) =>
              route.kind == NetworkRouteKind.direct ? direct : secureDns,
        );
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.appApi,
        );
        await expectLater(client.get(_apiUri), throwsA(isA<Object>()));
        expect(secureDns.requests, isEmpty);
        await policy.dispose();
      }

      final directHttp = _FakeClient(statusCode: 429, body: 'limited');
      final secureHttp = _FakeClient();
      final httpPolicy = NetworkAccessPolicy(
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) =>
            route.kind == NetworkRouteKind.direct ? directHttp : secureHttp,
      );
      final httpClient = PixivPolicyHttpClient(
        policy: httpPolicy,
        purpose: PixivDestinationPurpose.appApi,
      );
      final response = await httpClient.get(_apiUri);
      expect(response.statusCode, 429);
      expect(resolver.calls, 0);
      expect(secureHttp.requests, isEmpty);
      await httpPolicy.dispose();
    },
  );

  test(
    'diagnostics contain route metadata but no URL or credential material',
    () {
      final diagnostics = NetworkDiagnostics(maxEvents: 4);
      diagnostics.record(
        NetworkDiagnosticEvent(
          host: 'app-api.pixiv.net',
          purpose: PixivDestinationPurpose.appApi,
          route: NetworkRouteKind.direct,
          ipFamily: NetworkIpFamily.ipv4,
          failure: NetworkFailureKind.connect,
          latency: const Duration(milliseconds: 14),
          revision: const NetworkRevision(3, networkIdentity: 'wifi'),
        ),
      );
      final rendered = '${diagnostics.events.single.toMap()}';
      expect(rendered, contains('app-api.pixiv.net'));
      expect(rendered, contains('connect'));
      expect(rendered, isNot(contains('?code=')));
      expect(rendered, isNot(contains('access_token')));
      expect(rendered, isNot(contains('cookie')));
      expect(rendered, isNot(contains('203.0.113.10')));
    },
  );

  test('network revision and mode changes clear pooled routes', () async {
    final created = <NetworkRoute>[];
    final policy = NetworkAccessPolicy(
      clientFactory: (route, canonicalHost, _) {
        created.add(route);
        return _FakeClient();
      },
    );
    final first = policy.clientFor(
      PixivDestinationPurpose.appApi,
      NetworkRoute.direct(policy.revision),
      'app-api.pixiv.net',
    );
    expect(
      policy.clientFor(
        PixivDestinationPurpose.appApi,
        NetworkRoute.direct(policy.revision),
        'app-api.pixiv.net',
      ),
      same(first),
    );
    policy.setMode(NetworkMode.directOnly);
    final next = policy.advanceNetworkRevision(networkIdentity: 'cellular');
    expect(next.value, 1);
    expect(next.networkIdentity, 'cellular');
    expect(
      policy.clientFor(
        PixivDestinationPurpose.appApi,
        NetworkRoute.direct(policy.revision),
        'app-api.pixiv.net',
      ),
      isNot(same(first)),
    );
    await policy.dispose();
  });

  test('policy rejects private addresses from an injected resolver', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: 'must-not-send');
    final policy = NetworkAccessPolicy(
      resolver: _FakeResolver([InternetAddress('192.168.1.10')]),
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    await expectLater(
      client.get(_apiUri),
      throwsA(isA<SecureResolutionException>()),
    );
    expect(secureDns.requests, isEmpty);
  });

  test(
    'cancellation during direct transport prevents route fallback',
    () async {
      final direct = _GateFailureClient();
      final secureDns = _FakeClient(body: 'must-not-send');
      final resolver = _FakeResolver([InternetAddress('1.2.3.7')]);
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) =>
            route.kind == NetworkRouteKind.direct ? direct : secureDns,
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );
      final abort = Completer<void>();
      final operation = client.send(
        http.AbortableRequest('GET', _apiUri, abortTrigger: abort.future),
      );
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      direct.gate.complete();

      await expectLater(operation, throwsA(isA<SocketException>()));
      expect(resolver.calls, 0);
      expect(secureDns.requests, isEmpty);
    },
  );

  test(
    'API, OAuth and image cache use one app-scoped policy factory',
    () async {
      final policy = NetworkAccessPolicy(
        clientFactory: (_, _, _) => _FakeClient(),
      );
      final factory = PixivNetworkFactory(policy);
      expect(factory.apiClient.policy, same(policy));
      expect(factory.oauthClient.policy, same(policy));
      expect(
        factory.client(PixivDestinationPurpose.image).policy,
        same(policy),
      );
      await factory.dispose();
    },
  );

  test('production OAuth provider is backed by the policy factory', () {
    final policy = NetworkAccessPolicy(
      clientFactory: (_, _, _) => _FakeClient(),
    );
    final container = ProviderContainer(
      overrides: [networkAccessPolicyProvider.overrideWithValue(policy)],
    );
    addTearDown(container.dispose);

    final factory = container.read(pixivNetworkFactoryProvider);
    final service = container.read(oauthServiceProvider);
    expect(service.client, same(factory.client(PixivDestinationPurpose.oauth)));
  });

  test('per-host route memory skips the doomed direct attempt', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: '{"via":"secure-dns"}');
    final resolver = _FakeResolver([InternetAddress('1.2.3.8')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    // First request: direct fails, DoH tier succeeds, host is remembered.
    final first = await client.get(_apiUri);
    expect(first.statusCode, 200);
    expect(direct.requests, hasLength(1));
    expect(secureDns.requests, hasLength(2));
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);

    // Second request: the direct tier is skipped entirely.
    final second = await client.get(_apiUri);
    expect(second.statusCode, 200);
    expect(direct.requests, hasLength(1), reason: 'direct must be skipped');
    expect(secureDns.requests, hasLength(3));
    expect(
      resolver.calls,
      1,
      reason: 'the remembered strict tier is reused without a new lookup',
    );
  });

  test(
    'route memory expires and is cleared by mode/revision changes',
    () async {
      final direct = _FakeClient(
        failure: SocketException('Connection refused'),
      );
      final secureDns = _FakeClient(body: '{"via":"secure-dns"}');
      final resolver = _FakeResolver([InternetAddress('1.2.3.9')]);
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) =>
            route.kind == NetworkRouteKind.direct ? direct : secureDns,
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );
      await client.get(_apiUri);
      expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);

      // Past the TTL the host is no longer remembered.
      expect(
        policy.hasStrictRouteMemory(
          'app-api.pixiv.net',
          now: DateTime.now().add(const Duration(minutes: 11)),
        ),
        isFalse,
      );

      // A revision change (network handover) clears memory immediately.
      policy.advanceNetworkRevision(networkIdentity: 'cellular');
      expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isFalse);
    },
  );

  test('route memory is per-host, not global', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: '{"via":"secure-dns"}');
    final resolver = _FakeResolver([InternetAddress('1.2.3.10')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );
    final imageClient = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.image,
    );

    await client.get(_apiUri);
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);
    expect(policy.hasStrictRouteMemory('i.pximg.net'), isFalse);

    // The other host pays its own direct attempt — memory is per-host.
    await imageClient.get(
      Uri.parse('https://i.pximg.net/img-master/img/1/2/3/a.jpg'),
    );
    expect(direct.requests, hasLength(2));
    expect(policy.hasStrictRouteMemory('i.pximg.net'), isTrue);
  });

  test('API and download exits share one route ladder', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: '{"via":"secure-dns"}');
    final resolver = _FakeResolver([InternetAddress('1.2.3.11')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final apiClient = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );
    final imageClient = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.image,
    );

    await apiClient.get(_apiUri);
    expect(secureDns.requests, hasLength(2));
    await imageClient.get(
      Uri.parse('https://i.pximg.net/img-master/img/1/2/3/a.jpg'),
    );
    expect(secureDns.requests, hasLength(4));
    expect(direct.requests, hasLength(2));
    expect(resolver.calls, 2);
    // Both exits observe the same policy-owned route memory.
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);
    expect(policy.hasStrictRouteMemory('i.pximg.net'), isTrue);
  });

  test(
    'download transport cache identity includes the canonical host',
    () async {
      final clients = <String, _FakeClient>{};
      final policy = NetworkAccessPolicy(
        clientFactory: (route, host, _) => clients.putIfAbsent(
          host,
          () => _FakeClient(body: '{"host":"$host"}'),
        ),
      );
      final transport = PolicyDownloadTransport(policy: policy);
      addTearDown(() async {
        await transport.dispose();
        await policy.dispose();
      });

      Future<void> fetch(String host) async {
        final response = await transport.open(
          Uri.parse('https://$host/img-original/img/1_p0.jpg'),
          headers: const {},
          cancelToken: DownloadCancelToken(),
        );
        await response.stream.drain<void>();
        await response.close();
      }

      await fetch('i.pximg.net');
      await fetch('s.pximg.net');

      expect(clients.keys, containsAll(<String>['i.pximg.net', 's.pximg.net']));
      expect(
        clients['i.pximg.net']!.requests.map((request) => request.url.host),
        everyElement('i.pximg.net'),
      );
      expect(
        clients['s.pximg.net']!.requests.map((request) => request.url.host),
        everyElement('s.pximg.net'),
      );
    },
  );
}

final _apiUri = Uri.parse(
  'https://app-api.pixiv.net/v1/illust/recommended?offset=0',
);
