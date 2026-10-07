import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/test_preferences.dart';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/network/compat/auto_image_source.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_fast_route_store.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/compat/policy_download_transport.dart';
import 'package:parfait/core/network/compat/route_kind_store.dart';
import 'package:parfait/core/network/compat/secure_resolver.dart';
import 'package:parfait/core/settings/image_mirror.dart';

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

/// send() never resolves — simulates a socket that stalls before headers.
class _NeverSendClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// Emits [bytes] of body then stalls forever — a mid-body connection stall.
class _StallClient extends http.BaseClient {
  _StallClient([this.bytes = 1]);

  final int bytes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.multi((controller) {
        controller.add(List.filled(bytes, 1));
      }),
      200,
      request: request,
    );
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
  installMemoryPreferences();
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

  test('an empty GET prefers the strict tier over direct', () async {
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
    expect(
      direct.requests,
      isEmpty,
      reason: 'an unverified direct attempt is skipped when strict succeeded',
    );
    expect(secureDns.requests.map((request) => request.method), ['GET']);
    expect(secureDns.requests.single.url.host, 'app-api.pixiv.net');
    expect(secureDns.requests.single.url.port, 443);
  });

  test(
    'the strict tier is tried before an unverified direct attempt',
    () async {
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
      expect(resolver.calls, 1);
      expect(direct.requests.map((request) => request.method), ['GET']);
      expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);
    },
  );

  test(
    'a POST prefers the strict tier; direct is only a last resort',
    () async {
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
      expect(
        direct.requests,
        isEmpty,
        reason: 'the DoH tier answered; direct never needs an attempt',
      );
      expect(secureDns.requests.map((request) => request.method), ['POST']);
    },
  );

  test('a timed-out POST is never replayed across routes', () async {
    final doh = _ScriptedClient([TimeoutException('after send')]);
    final fallback = _FakeClient(body: 'must-not-send');
    final resolver = _FakeEchResolver(
      [InternetAddress('1.2.3.41')],
      frontAddresses: [InternetAddress('1.2.3.42')],
    );
    final policy = NetworkAccessPolicy(
      resolver: resolver,
      clientFactory: (route, canonicalHost, purpose) =>
          route.kind == NetworkRouteKind.insecureNoSni ? fallback : doh,
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
      throwsA(isA<TimeoutException>()),
    );
    expect(doh.requests.map((request) => request.method), ['POST']);
    expect(
      fallback.requests,
      isEmpty,
      reason: 'a delivered-but-timed-out POST must not be replayed',
    );
    expect(resolver.echCalls, 1, reason: 'the ECH tier was tried first');
  });

  test('a mutation prefers the ECH tier', () async {
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
        NetworkRouteKind.ech => ech,
        NetworkRouteKind.direct => direct,
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
    expect(ech.requests.map((request) => request.method), ['POST']);
    expect(
      direct.requests,
      isEmpty,
      reason: 'a successful ECH attempt must prevent lower tiers',
    );
    expect(doh.requests, isEmpty);
  });

  test('remembered ECH is reused only within its config TTL', () async {
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
    expect(direct.requests, isEmpty);
    expect(ech.requests, hasLength(1));

    now = base.add(const Duration(seconds: 20));
    await client.get(_apiUri);
    expect(
      policy.rememberedRouteKind('app-api.pixiv.net'),
      NetworkRouteKind.ech,
    );
    expect(direct.requests, isEmpty, reason: 'remembered ECH skips direct');
    expect(
      ech.requests,
      hasLength(2),
      reason: 'business request uses ECH once',
    );

    // A successful business request does not extend the DNS RR lifetime of
    // the ECH config that built this route.
    now = base.add(const Duration(seconds: 45));
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isFalse);
    expect(
      policy.rememberedGroupRouteKind(
        PixivDestinationPurpose.oauth,
        'oauth.secure.pixiv.net',
      ),
      isNull,
    );
  });

  test(
    'a verified ECH route is preferred by another Cloudflare host',
    () async {
      final direct = _FakeClient(
        failure: SocketException('Connection refused'),
      );
      final ech = _FakeClient(body: '{"route":"ech"}');
      final resolver = _FakeEchResolver(
        [InternetAddress('1.2.3.32')],
        frontAddresses: [InternetAddress('1.2.3.33')],
      );
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) =>
            route.kind == NetworkRouteKind.direct ? direct : ech,
      );
      addTearDown(policy.dispose);

      final api = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );
      final oauth = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.oauth,
      );

      await api.get(_apiUri);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.oauth,
          'oauth.secure.pixiv.net',
        ),
        NetworkRouteKind.ech,
      );
      expect(direct.requests, isEmpty);

      await oauth.get(Uri.parse('https://oauth.secure.pixiv.net/auth/token'));
      expect(
        direct.requests,
        isEmpty,
        reason: 'the verified Cloudflare-group ECH tier is attempted first',
      );

      policy.advanceNetworkRevision(networkIdentity: 'cellular');
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.appApi,
          'app-api.pixiv.net',
        ),
        isNull,
      );
    },
  );

  test('the explicit insecure tier is never promoted across hosts', () async {
    final failed = _FakeClient(failure: SocketException('Connection refused'));
    final insecure = _FakeClient(body: '{"route":"insecure"}');
    final policy = NetworkAccessPolicy(
      resolver: _FakeResolver([InternetAddress('1.2.3.34')]),
      insecureNoSniEnabled: true,
      clientFactory: (route, canonicalHost, _) =>
          route.kind == NetworkRouteKind.insecureNoSni ? insecure : failed,
    );
    addTearDown(policy.dispose);
    final client = PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.appApi,
    );

    final response = await client.get(_apiUri);
    expect(response.statusCode, 200);
    expect(
      policy.rememberedRouteKind('app-api.pixiv.net'),
      NetworkRouteKind.insecureNoSni,
    );
    expect(
      policy.rememberedGroupRouteKind(
        PixivDestinationPurpose.oauth,
        'oauth.secure.pixiv.net',
      ),
      isNull,
      reason: 'another host must still try its strict ladder first',
    );
  });

  test(
    'failed remembered route is invalidated without repeating its tier',
    () async {
      final direct = _FakeClient(
        failure: SocketException('Connection refused'),
      );
      final ech = _ScriptedClient([
        SocketException('Connection reset'), // first business GET fails
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
        'GET',
      ], reason: 'the failed ECH route is not sent again');
      expect(doh.requests.map((request) => request.method), ['GET']);
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
              route.kind == NetworkRouteKind.dohRealSni ? direct : secureDns,
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
            route.kind == NetworkRouteKind.dohRealSni ? directHttp : secureHttp,
      );
      final httpClient = PixivPolicyHttpClient(
        policy: httpPolicy,
        purpose: PixivDestinationPurpose.appApi,
      );
      final response = await httpClient.get(_apiUri);
      expect(response.statusCode, 429);
      expect(
        resolver.calls,
        greaterThanOrEqualTo(1),
        reason: 'each strict attempt resolves its host before sending',
      );
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
    'cancellation during the first strict attempt prevents fallback',
    () async {
      final direct = _GateFailureClient();
      final secureDns = _FakeClient(body: 'must-not-send');
      final resolver = _FakeResolver([InternetAddress('1.2.3.7')]);
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) =>
            route.kind == NetworkRouteKind.dohRealSni ? direct : secureDns,
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
      expect(resolver.calls, 1, reason: 'the strict tier resolved its host');
      expect(secureDns.requests, isEmpty);
    },
  );

  test(
    'API, OAuth and image clients use one app-scoped policy factory',
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

    // First request: the DoH tier answers; direct is never attempted.
    final first = await client.get(_apiUri);
    expect(first.statusCode, 200);
    expect(direct.requests, isEmpty);
    expect(secureDns.requests, hasLength(1));
    expect(policy.hasStrictRouteMemory('app-api.pixiv.net'), isTrue);

    // Second request: the direct tier is skipped entirely.
    final second = await client.get(_apiUri);
    expect(second.statusCode, 200);
    expect(direct.requests, isEmpty, reason: 'direct must be skipped');
    expect(secureDns.requests, hasLength(2));
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

    // The other host keeps its own tier — memory is per-host.
    await imageClient.get(
      Uri.parse('https://i.pximg.net/img-master/img/1/2/3/a.jpg'),
    );
    expect(direct.requests, isEmpty);
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
    expect(secureDns.requests, hasLength(1));
    await imageClient.get(
      Uri.parse('https://i.pximg.net/img-master/img/1/2/3/a.jpg'),
    );
    // Pixiv image hosts walk serially; without an ECH-capable resolver the
    // origin tier answers on the first send.
    expect(secureDns.requests, hasLength(2));
    expect(direct.requests, isEmpty);
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
  test(
    'an OAuth POST reaches the fast tier only after the strict tiers fail',
    () async {
      final insecure = _FakeClient(body: '{"ok":true}');
      final nowhere = _FakeClient(
        failure: SocketException('Connection refused'),
      );
      final policy = NetworkAccessPolicy(
        resolver: _FakeEchResolver(
          [InternetAddress('1.2.3.45')],
          frontAddresses: [InternetAddress('1.2.3.46')],
        ),
        insecureNoSniEnabled: true,
        fastRouteStore: PixivFastRouteStore(
          preferences: SharedPreferencesAsync(),
        ),
        clientFactory: (route, canonicalHost, _) =>
            route.kind == NetworkRouteKind.insecureNoSni ? insecure : nowhere,
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.oauth,
      );

      final response = await client.post(
        Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
        body: const {'code': 'one-shot'},
      );

      expect(response.statusCode, 200);
      // ECH, DoH-real-SNI and direct all failed first; the unverified fast
      // address is the last resort and gets the POST exactly once.
      expect(
        insecure.requests.map((request) => request.method),
        ['POST'],
        reason: 'the one-shot token exchange reaches the fast tier last, once',
      );
      expect(nowhere.requests, hasLength(3));
    },
  );

  test(
    'a failed fast-tier POST gives up without repeating the token exchange',
    () async {
      final insecure = _FakeClient(
        failure: SocketException('Connection reset'),
      );
      final direct = _FakeClient(body: '{"ok":true}');
      final strict = _FakeClient(
        failure: SocketException('Connection refused'),
      );
      final policy = NetworkAccessPolicy(
        resolver: _FakeEchResolver(
          [InternetAddress('1.2.3.47')],
          frontAddresses: [InternetAddress('1.2.3.48')],
        ),
        insecureNoSniEnabled: true,
        fastRouteStore: PixivFastRouteStore(
          preferences: SharedPreferencesAsync(),
        ),
        clientFactory: (route, canonicalHost, _) => switch (route.kind) {
          NetworkRouteKind.insecureNoSni => insecure,
          NetworkRouteKind.direct => direct,
          _ => strict,
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.oauth,
      );

      final response = await client.post(
        Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
        body: const {'code': 'one-shot'},
      );

      expect(response.statusCode, 200);
      expect(
        insecure.requests,
        isEmpty,
        reason: 'the direct tier already answered; the fast tier is not tried',
      );
      expect(direct.requests.map((request) => request.method), [
        'POST',
      ], reason: 'the POST succeeds on the tier that can actually handle it');
    },
  );

  group('image mirror integration', () {
    test('extra image hosts gain image trust and nothing else', () {
      final registry = PixivDestinationRegistry(
        extraImageHosts: {'i.pixiv.cat', 's.pixiv.cat'},
      );

      expect(
        registry
            .require(
              Uri.parse('https://i.pixiv.cat/img-original/img/1_p0.jpg'),
              PixivDestinationPurpose.image,
            )
            .canonicalHost,
        'i.pixiv.cat',
      );
      for (final purpose in [
        PixivDestinationPurpose.appApi,
        PixivDestinationPurpose.oauth,
        PixivDestinationPurpose.accountsWeb,
        PixivDestinationPurpose.pixivWeb,
      ]) {
        expect(
          () =>
              registry.require(Uri.parse('https://i.pixiv.cat/v1/x'), purpose),
          throwsA(isA<PixivDestinationException>()),
          reason: 'a mirror host must never become a $purpose target',
        );
      }
      expect(
        () => registry.require(
          Uri.parse('https://unregistered.example.com/a.jpg'),
          PixivDestinationPurpose.image,
        ),
        throwsA(isA<PixivDestinationException>()),
      );
    });

    test(
      'the image client rewrites to the mirror before destination resolution',
      () async {
        final mirror = ImageMirror.of('i.pixiv.cat');
        final direct = _FakeClient(
          failure: SocketException('Connection refused'),
        );
        final ech = _FakeClient(body: 'must-not-send');
        final secure = _FakeClient(body: '{"ok":true}');
        final resolver = _FakeEchResolver(
          [InternetAddress('1.2.3.60')],
          frontAddresses: [InternetAddress('1.2.3.61')],
        );
        final policy = NetworkAccessPolicy(
          registry: PixivDestinationRegistry(
            extraImageHosts: mirror.extraHosts,
          ),
          resolver: resolver,
          clientFactory: (route, canonicalHost, _) => switch (route.kind) {
            NetworkRouteKind.direct => direct,
            NetworkRouteKind.ech => ech,
            _ => secure,
          },
        );
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
          urlRewriter: mirror.rewrite,
        );

        final response = await client.get(
          Uri.parse('https://i.pximg.net/img-original/img/1_p0.jpg?x=1'),
          headers: const {'Referer': 'https://www.pixiv.net/'},
        );

        expect(response.statusCode, 200);
        expect(
          resolver.echCalls,
          0,
          reason: 'a third-party mirror never enters the Pixiv ECH tier',
        );
        expect(ech.requests, isEmpty);
        expect(direct.requests, isEmpty);
        // A cold mirror races its own top two tiers (noSni + dohRealSni);
        // both requests retarget to the mirror host.
        expect(secure.requests, hasLength(2));
        for (final request in secure.requests) {
          expect(request.url.host, 'i.pixiv.cat');
        }
        final sent = secure.requests.first;
        expect(sent.url.host, 'i.pixiv.cat');
        expect(sent.url.path, '/img-original/img/1_p0.jpg');
        expect(sent.url.query, 'x=1');
        expect(sent.headers['Referer'], 'https://www.pixiv.net/');
        expect(policy.hasStrictRouteMemory('i.pixiv.cat'), isTrue);
      },
    );

    test('the factory only rewrites image-purpose requests', () async {
      final mirror = ImageMirror.of('i.pixiv.cat');
      final backend = _FakeClient(body: '{}');
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(extraImageHosts: mirror.extraHosts),
        resolver: _FakeResolver([InternetAddress('1.2.3.62')]),
        clientFactory: (route, canonicalHost, _) => backend,
      );
      addTearDown(policy.dispose);
      final factory = PixivNetworkFactory(
        policy,
        imageUrlRewriter: mirror.rewrite,
      );

      await factory.apiClient.get(
        Uri.parse('https://app-api.pixiv.net/v1/illust/recommended'),
      );
      expect(backend.requests.single.url.host, 'app-api.pixiv.net');

      await factory
          .client(PixivDestinationPurpose.image)
          .get(Uri.parse('https://s.pximg.net/avatar/u/1.jpg'));
      expect(backend.requests.last.url.host, 's.pixiv.cat');
    });

    test('a rewritten host missing from the registry fails loudly', () async {
      final policy = NetworkAccessPolicy(
        clientFactory: (_, _, _) => _FakeClient(),
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
        urlRewriter: ImageMirror.of('i.pixiv.cat').rewrite,
      );

      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/a.jpg')),
        throwsA(isA<PixivDestinationException>()),
      );
    });

    test(
      'downloads follow the mirror and keep the rewritten prefix path',
      () async {
        final mirror = ImageMirror.of('https://proxy.example.com/pixiv');
        final backend = _FakeClient(body: 'bytes');
        final policy = NetworkAccessPolicy(
          registry: PixivDestinationRegistry(
            extraImageHosts: mirror.extraHosts,
          ),
          resolver: _FakeResolver([InternetAddress('1.2.3.63')]),
          clientFactory: (route, canonicalHost, _) => backend,
        );
        final transport = PolicyDownloadTransport(
          policy: policy,
          imageMirror: mirror,
        );
        addTearDown(() async {
          await transport.dispose();
          await policy.dispose();
        });

        final response = await transport.open(
          Uri.parse('https://i.pximg.net/img-original/img/2_p0.jpg'),
          headers: const {},
          cancelToken: DownloadCancelToken(),
        );
        await response.stream.drain<void>();
        await response.close();

        final sent = backend.requests.single;
        expect(sent.url.host, 'proxy.example.com');
        expect(sent.url.path, '/pixiv/img-original/img/2_p0.jpg');
      },
    );

    test('pximg route memory never leaks onto a mirror host', () async {
      final resolver = _FakeEchResolver(
        [InternetAddress('1.2.3.64')],
        frontAddresses: [InternetAddress('1.2.3.67')],
      );
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) => switch (route.kind) {
          NetworkRouteKind.ech ||
          NetworkRouteKind.noSni => _FakeClient(body: 'ok'),
          _ => _FakeClient(failure: SocketException('Connection refused')),
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      await client.get(Uri.parse('https://i.pximg.net/a.jpg'));
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        NetworkRouteKind.ech,
        reason: 'pximg remembers its own ECH success',
      );
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pixiv.re',
        ),
        isNull,
        reason:
            'the pximg preference must not seed the mirror group — the ECH '
            'config only covers pixiv hosts',
      );

      // The mirror still tries its own noSni tier first (its fallback
      // ordering), and that success seeds the *mirror* group instead.
      await client.get(Uri.parse('https://i.pixiv.re/a.jpg'));
      expect(policy.rememberedRouteKind('i.pixiv.re'), NetworkRouteKind.noSni);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pixiv.re',
        ),
        NetworkRouteKind.noSni,
      );
    });

    test(
      'a mirror empty-SNI certificate mismatch falls through to real SNI',
      () async {
        final certError = rhttp.RhttpInvalidCertificateException(
          request: rhttp.HttpRequest(
            method: rhttp.HttpMethod.get,
            url: 'https://i.pixiv.re/a.jpg',
          ),
          message: 'default vhost certificate does not match i.pixiv.re',
        );
        final attempts = <NetworkRouteKind>[];
        final policy = NetworkAccessPolicy(
          registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
          resolver: _FakeResolver([InternetAddress('1.2.3.65')]),
          clientFactory: (route, canonicalHost, _) {
            attempts.add(route.kind);
            return route.kind == NetworkRouteKind.noSni
                ? _FakeClient(failure: certError)
                : _FakeClient(body: 'ok');
          },
        );
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        final response = await client.get(
          Uri.parse('https://i.pixiv.re/a.jpg'),
        );
        expect(response.statusCode, 200);
        expect(attempts, [
          NetworkRouteKind.noSni,
          NetworkRouteKind.dohRealSni,
        ], reason: 'empty-SNI cert failure advances instead of aborting');
        expect(
          policy.rememberedRouteKind('i.pixiv.re'),
          NetworkRouteKind.dohRealSni,
        );
      },
    );

    test('a real-SNI certificate mismatch stays terminal', () async {
      final certError = rhttp.RhttpInvalidCertificateException(
        request: rhttp.HttpRequest(
          method: rhttp.HttpMethod.get,
          url: 'https://i.pixiv.re/a.jpg',
        ),
        message: 'hostname mismatch',
      );
      final attempts = <NetworkRouteKind>[];
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
        resolver: _FakeResolver([InternetAddress('1.2.3.66')]),
        clientFactory: (route, canonicalHost, _) {
          attempts.add(route.kind);
          return route.kind == NetworkRouteKind.noSni
              ? _FakeClient(failure: SocketException('Connection refused'))
              : _FakeClient(failure: certError);
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      await expectLater(
        client.get(Uri.parse('https://i.pixiv.re/a.jpg')),
        throwsA(same(certError)),
      );
      expect(attempts, [
        NetworkRouteKind.noSni,
        NetworkRouteKind.dohRealSni,
      ], reason: 'a real-SNI mismatch never falls through to direct');
    });
  });

  group('stream idle guard', () {
    test('send() surfaces a headers timeout for image clients', () async {
      final policy = NetworkAccessPolicy(
        imageHeadersTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => _NeverSendClient(),
      );
      addTearDown(policy.dispose);
      final client = policy.clientFor(
        PixivDestinationPurpose.image,
        NetworkRoute.direct(policy.revision),
        'i.pximg.net',
      );

      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/a.jpg')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('the response body errors after an idle gap', () async {
      final policy = NetworkAccessPolicy(
        imageIdleTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => _StallClient(),
      );
      addTearDown(policy.dispose);
      final client = policy.clientFor(
        PixivDestinationPurpose.image,
        NetworkRoute.direct(policy.revision),
        'i.pximg.net',
      );

      final response = await client.send(
        http.Request('GET', Uri.parse('https://i.pximg.net/a.jpg')),
      );
      await expectLater(
        response.stream.toList(),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('non-image clients are not wrapped', () async {
      final inner = _NeverSendClient();
      final policy = NetworkAccessPolicy(
        imageHeadersTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => inner,
      );
      addTearDown(policy.dispose);
      final client = policy.clientFor(
        PixivDestinationPurpose.appApi,
        NetworkRoute.direct(policy.revision),
        'app-api.pixiv.net',
      );

      expect(identical(client, inner), isTrue);
    });
  });

  // Racing is for mirrors only; pixiv's own image hosts stay serial on ECH
  // (see the 'pixiv image hosts stay on ECH' group).
  group('cold-start image racing', () {
    final imageUri = Uri.parse('https://i.pixiv.re/img-master/img/x_p0.jpg');
    PixivDestinationRegistry mirrorRegistry() =>
        PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'});

    test(
      'a cold mirror GET races the top two tiers and keeps the winner',
      () async {
        final noSni = _FakeClient(body: 'noSni');
        final realSni = _DelayedClient(
          _FakeClient(body: 'realSni'),
          const Duration(milliseconds: 200),
        );
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: _FakeResolver([InternetAddress('1.2.3.4')]),
          clientFactory: (route, _, _) => switch (route.kind) {
            NetworkRouteKind.noSni => noSni,
            _ => realSni,
          },
        );
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        final response = await client.get(imageUri);

        expect(response.statusCode, 200);
        // Both top tiers were attempted in parallel.
        expect(noSni.requests, hasLength(1));
        expect(realSni.requests, hasLength(1));
        // The faster tier won and is remembered for the next request.
        expect(
          policy.rememberedRouteKind('i.pixiv.re'),
          NetworkRouteKind.noSni,
        );
      },
    );

    test(
      'a warm host does not race — the remembered route is used alone',
      () async {
        final client = _FakeClient(body: 'ok');
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: _FakeResolver([InternetAddress('1.2.3.4')]),
          clientFactory: (_, _, _) => client,
        );
        addTearDown(policy.dispose);
        final httpClient = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        await httpClient.get(imageUri);
        await httpClient.get(imageUri);

        // Cold first request raced two tiers; the second request goes
        // straight to the remembered route — one send each leg.
        expect(client.requests, hasLength(3));
        expect(policy.rememberedRouteKind('i.pixiv.re'), isNotNull);
      },
    );

    test('a cold API GET stays serial — racing is image-only', () async {
      final client = _FakeClient(body: 'ok');
      final policy = NetworkAccessPolicy(
        resolver: _FakeResolver([InternetAddress('1.2.3.4')]),
        clientFactory: (_, _, _) => client,
      );
      addTearDown(policy.dispose);
      final httpClient = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );

      await httpClient.get(_apiUri);

      // The strict tier answered; no second tier was sent in parallel.
      expect(client.requests, hasLength(1));
    });

    test('both raced tiers failing falls back to the serial ladder', () async {
      final failing = _FakeClient(failure: const SocketException('refused'));
      final direct = _FakeClient(body: 'direct');
      final policy = NetworkAccessPolicy(
        registry: mirrorRegistry(),
        resolver: _FakeResolver([InternetAddress('1.2.3.4')]),
        clientFactory: (route, _, _) =>
            route.kind == NetworkRouteKind.direct ? direct : failing,
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      final response = await client.get(imageUri);

      expect(response.statusCode, 200);
      expect(failing.requests, hasLength(2));
      expect(direct.requests, hasLength(1));
      expect(policy.rememberedRouteKind('i.pixiv.re'), NetworkRouteKind.direct);
    });

    test(
      'a persisted route kind seeds the group preference on warm-up',
      () async {
        SharedPreferencesAsyncPlatform.instance = memoryPreferences();
        final preferences = SharedPreferencesAsync();
        final store = RouteKindStore(preferences: preferences);
        // A previous session learned that dohRealSni works for mirrors.
        await store.remember('initial', 'imageMirror', 'dohRealSni');

        final noSni = _FakeClient(failure: const SocketException('refused'));
        final realSni = _FakeClient(body: 'realSni');
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: _FakeResolver([InternetAddress('1.2.3.4')]),
          routeKindStore: store,
          clientFactory: (route, _, _) => switch (route.kind) {
            NetworkRouteKind.noSni => noSni,
            _ => realSni,
          },
        );
        addTearDown(policy.dispose);
        await policy.warmUp();
        // warmUp's seeding is fire-and-forget; let it land before racing.
        await Future<void>.delayed(Duration.zero);

        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );
        final response = await client.get(imageUri);

        expect(response.statusCode, 200);
        // The seeded preference made dohRealSni the first tier — noSni was
        // never raced because a group preference exists (not cold).
        expect(noSni.requests, isEmpty);
        expect(realSni.requests, hasLength(1));
      },
    );
  });

  group('pixiv image hosts stay on ECH', () {
    final imageUri = Uri.parse('https://i.pximg.net/img-master/img/x_p0.jpg');
    late List<NetworkRouteKind> attempts;
    late Set<NetworkRouteKind> down;
    late DateTime now;

    setUp(() {
      attempts = [];
      down = {};
      now = DateTime(2026, 10, 3, 12);
    });

    NetworkAccessPolicy ladderPolicy({
      RouteKindStore? store,
      PixivDestinationRegistry? registry,
    }) {
      final policy = NetworkAccessPolicy(
        registry: registry,
        resolver: _FakeEchResolver(
          [InternetAddress('1.2.3.80')],
          frontAddresses: [InternetAddress('1.2.3.81')],
        ),
        routeKindStore: store,
        clock: () => now,
        clientFactory: (route, _, _) => _KindClient(route.kind, attempts, down),
      );
      addTearDown(policy.dispose);
      return policy;
    }

    /// One image GET; returns the route kinds it was sent on, in order.
    Future<List<NetworkRouteKind>> fetch(NetworkAccessPolicy policy) async {
      attempts.clear();
      final response = await PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      ).get(imageUri);
      expect(response.statusCode, 200);
      return List.of(attempts);
    }

    Future<void> coolEch(NetworkAccessPolicy policy) async {
      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.noSni,
      ], reason: 'two failures in a row cool ECH down');
    }

    test('a cold GET goes to ECH alone instead of racing', () async {
      final policy = ladderPolicy();

      expect(await fetch(policy), [NetworkRouteKind.ech]);
      expect(policy.rememberedRouteKind('i.pximg.net'), NetworkRouteKind.ech);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        NetworkRouteKind.ech,
      );
    });

    test('one ECH failure only moves that request', () async {
      final policy = ladderPolicy();
      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);

      down.clear();
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
      ], reason: 'the remembered origin route gives way to ECH');
      expect(policy.rememberedRouteKind('i.pximg.net'), NetworkRouteKind.ech);
    });

    test('the cooldown doubles after every failed retry, capped', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      var cooldown = const Duration(minutes: 1);
      for (final next in const [2, 4, 8, 10, 10]) {
        now = now.add(cooldown - const Duration(seconds: 1));
        expect(await fetch(policy), [
          NetworkRouteKind.noSni,
        ], reason: 'still cooling within $cooldown');
        now = now.add(const Duration(seconds: 1));
        expect(await fetch(policy), [
          NetworkRouteKind.ech,
          NetworkRouteKind.noSni,
        ], reason: 'ECH is retried once $cooldown has passed');
        cooldown = Duration(minutes: next);
      }
    });

    test('an ECH success clears the failure count', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      now = now.add(const Duration(minutes: 1));
      down.clear();
      expect(await fetch(policy), [NetworkRouteKind.ech]);

      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ], reason: 'one failure after a success does not cool ECH yet');
    });

    test('a cooling ECH tier is still the last resort', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      down
        ..clear()
        ..addAll({
          NetworkRouteKind.noSni,
          NetworkRouteKind.dohRealSni,
          NetworkRouteKind.direct,
        });
      expect(await fetch(policy), [
        NetworkRouteKind.noSni,
        NetworkRouteKind.dohRealSni,
        NetworkRouteKind.direct,
        NetworkRouteKind.ech,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
      ], reason: 'that ECH success ended the cooldown');
    });

    test('a network change forgets the cooldown', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      down.clear();
      policy.advanceNetworkRevision(networkIdentity: 'cellular');
      expect(await fetch(policy), [NetworkRouteKind.ech]);
    });

    test('origin-tier successes are neither shared nor persisted', () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final policy = ladderPolicy(
        store: RouteKindStore(preferences: SharedPreferencesAsync()),
      );
      Future<String?> persistedImageKind() async {
        // Writes are fire-and-forget; read back through a fresh store.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final reloaded = RouteKindStore(preferences: SharedPreferencesAsync());
        return (await reloaded.kindsFor('initial'))?['image'];
      }

      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        isNull,
      );
      // Selecting ECH may already have stored it; the origin tier that
      // actually carried the request must not replace it.
      expect(await persistedImageKind(), isNot('noSni'));

      down.clear();
      expect(await fetch(policy), [NetworkRouteKind.ech]);
      expect(await persistedImageKind(), 'ech');
    });

    test('a persisted origin-tier image preference is ignored', () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final store = RouteKindStore(preferences: SharedPreferencesAsync());
      // Written by a version that let the origin tier win the race.
      await store.remember('initial', 'image', 'noSni');
      await store.remember('initial', 'imageMirror', 'dohRealSni');
      final policy = ladderPolicy(
        store: store,
        registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
      );
      await policy.warmUp();
      await Future<void>.delayed(Duration.zero);

      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        isNull,
      );
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pixiv.re',
        ),
        NetworkRouteKind.dohRealSni,
        reason: 'mirror preferences are still honored',
      );
      expect(await fetch(policy), [NetworkRouteKind.ech]);
    });
  });

  group('auto image source', () {
    NetworkAccessPolicy autoPolicy(
      http.Client Function(String host) clientFor,
    ) {
      return NetworkAccessPolicy(
        registry: PixivDestinationRegistry(
          extraImageHosts: Set<String>.of(ImageMirror.autoCandidates),
        ),
        resolver: _FakeResolver([InternetAddress('1.2.3.62')]),
        clientFactory: (route, canonicalHost, purpose) =>
            clientFor(canonicalHost),
      );
    }

    test('the winner persists scoped to the network identity', () async {
      installMemoryPreferences();
      final source = AutoImageSource(preferences: SharedPreferencesAsync());
      await source.remember('wifi', 'i.pixiv.re');

      expect(await source.winnerFor('wifi'), 'i.pixiv.re');
      expect(await source.winnerFor('cellular'), isNull);
      // A fresh instance reads the same store — the winner survives a
      // cold start.
      final reloaded = AutoImageSource(preferences: SharedPreferencesAsync());
      expect(await reloaded.winnerFor('wifi'), 'i.pixiv.re');
    });

    test('a corrupted blob resolves to null instead of crashing', () async {
      installMemoryPreferences(const {
        'pixiv.network.auto_image_source.v1': 'not-json{',
      });
      final source = AutoImageSource(preferences: SharedPreferencesAsync());
      expect(await source.winnerFor('wifi'), isNull);
    });

    test('a stored winner outside the candidate list is ignored', () async {
      installMemoryPreferences(const {
        'pixiv.network.auto_image_source.v1': '{"evil.example.com": "x"}',
      });
      final source = AutoImageSource(preferences: SharedPreferencesAsync());
      expect(await source.winnerFor('evil.example.com'), isNull);
    });

    test('race picks the fastest transfer, not the first response', () async {
      final big = List.filled(32 * 1024, 7);
      final policy = autoPolicy(
        (host) => switch (host) {
          // Direct answers fast but its body arrives after a delay — a
          // TTFB race would crown it; throughput ranking must not.
          'i.pximg.net' => _DelayedClient(
            _FakeClient(body: utf8.decode(big)),
            const Duration(milliseconds: 300),
          ),
          'i.pixiv.re' => _FakeClient(body: utf8.decode(big)),
          _ => _FakeClient(failure: const SocketException('refused')),
        },
      );
      addTearDown(policy.dispose);

      final result = await AutoImageSource.race(policy);
      expect(result?.host, 'i.pixiv.re');
      expect(result?.bps, isNotNull);
    });

    test(
      'race falls back to the first reachable host without a body',
      () async {
        final policy = autoPolicy(
          (host) => switch (host) {
            'i.pixiv.re' => _FakeClient(body: '{}'), // reachable, unmeasurable
            _ => _FakeClient(failure: const SocketException('refused')),
          },
        );
        addTearDown(policy.dispose);

        final result = await AutoImageSource.race(policy);
        expect(result?.host, 'i.pixiv.re');
        expect(result?.bps, isNull);
      },
    );

    test('race returns null when every candidate fails', () async {
      final policy = autoPolicy(
        (_) => _FakeClient(failure: const SocketException('refused')),
      );
      addTearDown(policy.dispose);

      expect(await AutoImageSource.race(policy), isNull);
    });

    test('a body cut off by the deadline ranks on what it delivered', () async {
      final policy = autoPolicy(
        (host) => switch (host) {
          // Throttled: 40 KB arrive, the rest not before the deadline.
          'i.pximg.net' => _StallClient(40 * 1024),
          // Answered, but too little data to measure.
          'i.pixiv.re' => _StallClient(1024),
          _ => _FakeClient(failure: const SocketException('refused')),
        },
      );
      addTearDown(policy.dispose);

      final result = await AutoImageSource.race(
        policy,
        timeout: const Duration(milliseconds: 300),
      );
      expect(result?.host, 'i.pximg.net');
      expect(result?.bps, isNotNull);
    });

    test('a probe cut off below the measurable minimum loses', () async {
      final policy = autoPolicy(
        (host) => host == 'i.pixiv.re'
            ? _StallClient(1024)
            : _FakeClient(failure: const SocketException('refused')),
      );
      addTearDown(policy.dispose);

      expect(
        await AutoImageSource.race(
          policy,
          timeout: const Duration(milliseconds: 300),
        ),
        isNull,
        reason: 'headers alone do not make a usable source',
      );
    });

    test(
      'a mirror host exhausting its ladder reports onImageHostExhausted',
      () async {
        final exhausted = <String>[];
        final policy = autoPolicy(
          (_) => _FakeClient(failure: const SocketException('refused')),
        );
        policy.onImageHostExhausted = exhausted.add;
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        await expectLater(
          client.get(Uri.parse('https://i.pixiv.re/img/a.jpg')),
          throwsA(anything),
        );
        expect(exhausted, ['i.pixiv.re']);
      },
    );

    test('canonical pximg hosts never trigger onImageHostExhausted', () async {
      final exhausted = <String>[];
      final policy = autoPolicy(
        (_) => _FakeClient(failure: const SocketException('refused')),
      );
      policy.onImageHostExhausted = exhausted.add;
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/img/a.jpg')),
        throwsA(anything),
      );
      expect(exhausted, isEmpty);
    });
  });

  group('network modes', () {
    Future<List<NetworkRouteKind>> runExhaustingLadder(NetworkMode mode) async {
      final order = <NetworkRouteKind>[];
      final policy = NetworkAccessPolicy(
        resolver: _FakeResolver([InternetAddress('1.2.3.70')]),
        insecureNoSniEnabled: true,
        mode: mode,
        clientFactory: (route, canonicalHost, purpose) {
          order.add(route.kind);
          return _FakeClient(failure: const SocketException('refused'));
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );
      await expectLater(
        client.get(Uri.parse('https://app-api.pixiv.net/v1/ping')),
        throwsA(anything),
      );
      return order;
    }

    test('automatic keeps direct ahead of the insecure bootstrap', () async {
      final order = await runExhaustingLadder(NetworkMode.automatic);
      // ECH yields no route without an ECH-capable resolver, so the
      // observable ladder is DoH → direct → insecure bootstrap.
      expect(order, [
        NetworkRouteKind.dohRealSni,
        NetworkRouteKind.direct,
        NetworkRouteKind.insecureNoSni,
      ]);
    });

    test('compatPrefer walks every compat tier before direct', () async {
      final order = await runExhaustingLadder(NetworkMode.compatPrefer);
      expect(order, [
        NetworkRouteKind.dohRealSni,
        NetworkRouteKind.insecureNoSni,
        NetworkRouteKind.direct,
      ]);
    });

    test('effectiveRouteSnapshot reports settled per-host kinds', () async {
      final policy = NetworkAccessPolicy(
        resolver: _FakeResolver([InternetAddress('1.2.3.71')]),
        clientFactory: (route, canonicalHost, purpose) =>
            _FakeClient(body: '{}'),
      );
      addTearDown(policy.dispose);
      expect(policy.effectiveRouteSnapshot(), isEmpty);

      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );
      await client.get(Uri.parse('https://i.pximg.net/img/a.jpg'));

      final snapshot = policy.effectiveRouteSnapshot();
      expect(snapshot.keys, contains('i.pximg.net'));
      expect(snapshot['i.pximg.net'], isNotNull);
    });
  });
}

/// Answers 200 unless its route kind is in [down]; logs every send's kind.
class _KindClient extends http.BaseClient {
  _KindClient(this.kind, this.log, this.down);

  final NetworkRouteKind kind;
  final List<NetworkRouteKind> log;
  final Set<NetworkRouteKind> down;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    log.add(kind);
    if (down.contains(kind)) {
      throw const SocketException('Connection refused');
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('ok')),
      200,
      request: request,
    );
  }
}

/// Delays the inner send so race tests can pick the winner deterministically.
class _DelayedClient extends http.BaseClient {
  _DelayedClient(this._inner, this._delay);

  final _FakeClient _inner;
  final Duration _delay;

  /// Records on arrival — the delay simulates a slow tier, and a test
  /// asserting "the loser was also sent" must not depend on it finishing.
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await Future<void>.delayed(_delay);
    return _inner.send(request);
  }
}

final _apiUri = Uri.parse(
  'https://app-api.pixiv.net/v1/illust/recommended?offset=0',
);
