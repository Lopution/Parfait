import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/secure_resolver.dart';
import 'package:pixiv_func/core/network/compat/webview_route.dart';

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
      expect(
        TransportFailureClassifier.classify(
          HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ).kind,
        NetworkFailureKind.certificateMismatch,
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
      expect(
        TransportFailureClassifier.isFallbackEligible(
          HandshakeException('certificate mismatch'),
        ),
        isFalse,
      );
      expect(
        TransportFailureClassifier.isFallbackEligible(
          NetworkFailureException(NetworkFailureKind.auth),
        ),
        isFalse,
      );
    },
  );

  test('automatic mode falls back only for a safe empty GET', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: '{"route":"secure-dns"}');
    final resolver = _FakeResolver([InternetAddress('1.2.3.4')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route) =>
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
    expect(secureDns.requests, hasLength(1));
    expect(secureDns.requests.single.url.host, 'app-api.pixiv.net');
    expect(secureDns.requests.single.url.port, 443);
  });

  test('POST never replays after a possible body send', () async {
    final direct = _FakeClient(failure: SocketException('Connection reset'));
    final secureDns = _FakeClient(body: 'should-not-send');
    final resolver = _FakeResolver([InternetAddress('1.2.3.5')]);
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route) =>
          route.kind == NetworkRouteKind.direct ? direct : secureDns,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    await expectLater(
      client.post(
        Uri.parse('https://app-api.pixiv.net/v1/illust/bookmark/add'),
        body: const {'illust_id': '1'},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(resolver.calls, 0);
    expect(secureDns.requests, isEmpty);
  });

  test(
    'HTTP, auth, certificate and cancellation responses do not fallback',
    () async {
      final resolver = _FakeResolver([InternetAddress('1.2.3.6')]);
      for (final failure in <Object>[
        HandshakeException('certificate mismatch'),
        NetworkFailureException(NetworkFailureKind.auth),
        NetworkFailureException(NetworkFailureKind.cancelled),
      ]) {
        final direct = _FakeClient(failure: failure);
        final secureDns = _FakeClient();
        final policy = NetworkAccessPolicy(
          resolver: resolver,
          clientFactory: (route) =>
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
        clientFactory: (route) =>
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

  test(
    'DoH parser accepts matching public records and preserves the minimum TTL',
    () async {
      final resolver = DohResolver(
        client: MockClient((request) async {
          final type = request.url.queryParameters['type'];
          final body = jsonEncode({
            'Status': 0,
            'Answer': [
              {
                'name': 'app-api.pixiv.net.',
                'type': type == 'A' ? 1 : 28,
                'TTL': type == 'A' ? 42 : 17,
                'data': type == 'A' ? '1.2.3.4' : '2001:4860:4860::8888',
              },
              {
                'name': 'app-api.pixiv.net.',
                'type': 1,
                'TTL': 1,
                'data': '192.168.1.1',
              },
            ],
          });
          return http.Response(body, 200);
        }),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.resolve(
        'app-api.pixiv.net',
        revision: const NetworkRevision(2),
      );
      expect(
        result.addresses.map((address) => address.address),
        containsAll(['1.2.3.4', '2001:4860:4860::8888']),
      );
      expect(
        result.addresses.map((address) => address.address),
        isNot(contains('192.168.1.1')),
      );
      expect(result.ttl, const Duration(seconds: 17));
    },
  );

  test(
    'network revision and mode changes clear pooled routes and health',
    () async {
      final created = <NetworkRoute>[];
      final policy = NetworkAccessPolicy(
        clientFactory: (route) {
          created.add(route);
          return _FakeClient();
        },
      );
      final first = policy.clientFor(
        PixivDestinationPurpose.appApi,
        NetworkRoute.direct(policy.revision),
      );
      expect(
        policy.clientFor(
          PixivDestinationPurpose.appApi,
          NetworkRoute.direct(policy.revision),
        ),
        same(first),
      );
      policy.recordHealth(
        host: 'app-api.pixiv.net',
        route: NetworkRoute.direct(policy.revision),
        failure: NetworkFailureKind.connect,
      );
      expect(policy.healthEntries, isNotEmpty);

      policy.setMode(NetworkMode.directOnly);
      expect(policy.healthEntries, isEmpty);
      final next = policy.advanceNetworkRevision(networkIdentity: 'cellular');
      expect(next.value, 1);
      expect(next.networkIdentity, 'cellular');
      expect(
        policy.clientFor(
          PixivDestinationPurpose.appApi,
          NetworkRoute.direct(policy.revision),
        ),
        isNot(same(first)),
      );
      await policy.dispose();
    },
  );

  test('policy rejects private addresses from an injected resolver', () async {
    final direct = _FakeClient(failure: SocketException('Connection refused'));
    final secureDns = _FakeClient(body: 'must-not-send');
    final policy = NetworkAccessPolicy(
      resolver: _FakeResolver([InternetAddress('192.168.1.10')]),
      clientFactory: (route) =>
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
        clientFactory: (route) =>
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
      final policy = NetworkAccessPolicy(clientFactory: (_) => _FakeClient());
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

  test(
    'ECH and WebView loopback remain fail-closed without capability proof',
    () async {
      const incomplete = EchCapabilityEvidence(
        endpointSupport: true,
        transportSupport: true,
        api36RequiredMode: false,
        trustValidated: true,
        cancellationValidated: true,
        streamingValidated: true,
        poolingValidated: true,
      );
      expect(EchCapabilityGate(incomplete).approved, isFalse);

      final route = WebViewRoutePolicy(
        registry: PixivDestinationRegistry(),
        capabilities: const UnsupportedWebKitCapabilities(),
      );
      final decision = await route.probe(
        Uri.parse('https://app-api.pixiv.net/web/v1/login'),
      );
      expect(decision.allowed, isTrue);
      expect(decision.compatibilityModeAvailable, isFalse);
      expect(route.listenerCreated, isFalse);

      final session = await WebViewRouteSession.open(
        policy: route,
        uri: Uri.parse('https://app-api.pixiv.net/web/v1/login'),
      );
      expect(session.isClosed, isFalse);
      await session.close();
      expect(session.isClosed, isTrue);
      await session.close();
    },
  );
}

final _apiUri = Uri.parse(
  'https://app-api.pixiv.net/v1/illust/recommended?offset=0',
);
