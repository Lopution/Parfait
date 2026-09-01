import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pixiv_func/core/network/compat/dns_message.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/secure_resolver.dart';

/// Scripted DoH server standing in for `https://1.1.1.1/dns-query`.
class _FakeDohServer {
  _FakeDohServer({String? address, this.statusCode = 200, this.rcode = 0}) {
    ip = address == null
        ? InternetAddress('1.2.3.4')
        : InternetAddress(address);
  }

  late final InternetAddress ip;
  final int statusCode;
  final int rcode;
  int ttl = 60;
  final requests = <http.Request>[];
  Completer<void>? block;
  Duration delay = Duration.zero;

  /// When set, HTTPS (type 65) queries for this host return an answer whose
  /// RDATA carries this ech SvcParam body. When null, type 65 queries
  /// return NOERROR with zero answers.
  Uint8List? httpsEchRdata;
  int httpsTtl = 60;

  Future<http.StreamedResponse> handle(http.Request request) async {
    requests.add(request);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (block != null) await block!.future;
    if (statusCode != 200) {
      return http.StreamedResponse(
        Stream<List<int>>.value(const []),
        statusCode,
        request: request,
      );
    }
    final query = decodeResponse(request.bodyBytes);
    final id = query.id;
    final name = query.question?.name ?? '';
    final qtype = query.question?.type ?? 1;
    if (qtype == 65) {
      final answer = _httpsRecord(id, name, httpsEchRdata, ttl: httpsTtl);
      if (answer == null) {
        // NOERROR, zero answers.
        return http.StreamedResponse(
          Stream<List<int>>.value([
            ..._header(id, 0x8180 | (rcode & 0x0f), 1, 0),
            ..._question(name, type: 65),
          ]),
          200,
          request: request,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value([
          ..._header(id, 0x8180 | (rcode & 0x0f), 1, 1),
          ..._question(name, type: 65),
          ...answer,
        ]),
        200,
        request: request,
      );
    }
    // A single A answer pointing at this server's IP, with the scripted TTL.
    final answer = _aRecord(id, name, ip, ttl: ttl);
    var flags = 0x8180 | (rcode & 0x0f);
    final header = _header(id, flags, 1, 1);
    final question = _question(name);
    return http.StreamedResponse(
      Stream<List<int>>.value([...header, ...question, ...answer]),
      200,
      request: request,
    );
  }
}

/// HTTPS record answer: pointer to question name, type 65, class IN.
List<int>? _httpsRecord(
  int id,
  String name,
  Uint8List? echRdata, {
  int ttl = 60,
}) {
  if (echRdata == null) return null;
  final out = <int>[];
  out.addAll([0xc0, 0x0c]);
  out.addAll([0, 65, 0, 1]);
  out.addAll([
    (ttl >> 24) & 0xff,
    (ttl >> 16) & 0xff,
    (ttl >> 8) & 0xff,
    ttl & 0xff,
  ]);
  out.addAll([(echRdata.length >> 8) & 0xff, echRdata.length & 0xff]);
  out.addAll(echRdata);
  return out;
}

/// HTTPS RDATA with the `ech` SvcParam (key 5).
Uint8List _echRdata(List<int> echBytes) {
  final out = <int>[0, 1]; // priority (16-bit, RFC 9460 §2.2)
  for (final label in 'cloudflare-ech.com'.split('.')) {
    out.add(label.length);
    out.addAll(label.codeUnits);
  }
  out.add(0);
  out.addAll([0, 5]); // key 5
  out.addAll([(echBytes.length >> 8) & 0xff, echBytes.length & 0xff]);
  out.addAll(echBytes);
  return Uint8List.fromList(out);
}

List<int> _header(int id, int flags, int qd, int an) {
  final out = <int>[];
  void u16(int v) {
    out.add((v >> 8) & 0xff);
    out.add(v & 0xff);
  }

  u16(id);
  u16(flags);
  u16(qd);
  u16(an);
  u16(0);
  u16(0);
  return out;
}

List<int> _question(String name, {int type = 1}) {
  final out = <int>[];
  for (final label in name.split('.')) {
    out.add(label.length);
    out.addAll(label.codeUnits);
  }
  out.add(0);
  out.addAll([0, type, 0, 1]);
  return out;
}

List<int> _aRecord(int id, String name, InternetAddress ip, {int ttl = 60}) {
  final out = <int>[];
  out.addAll([0xc0, 0x0c]); // pointer to question name
  out.addAll([0, 1, 0, 1]); // A, IN
  out.addAll([
    (ttl >> 24) & 0xff,
    (ttl >> 16) & 0xff,
    (ttl >> 8) & 0xff,
    ttl & 0xff,
  ]);
  out.addAll([0, 4]);
  out.addAll(ip.rawAddress.isNotEmpty ? ip.rawAddress : [9, 9, 9, 9]);
  return out;
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.servers);

  final List<_FakeDohServer> servers;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    requests.add(req);
    final server = servers.firstWhere(
      (s) => request.url.host == s.ip.address,
      orElse: () => throw StateError('unexpected endpoint ${request.url}'),
    );
    return server.handle(req);
  }
}

const _revision = NetworkRevision(0);

void main() {
  test('resolves a host to its public address via DoH wire format', () async {
    final server = _FakeDohServer(address: '1.1.1.1');
    final client = _FakeClient([server]);
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query'],
      client: client,
    );
    addTearDown(resolver.dispose);

    final result = await resolver.resolve(
      'app-api.pixiv.net',
      revision: _revision,
    );

    expect(result.addresses.single.address, server.ip.address);
    expect(result.dnsSource, DnsSource.doh);
    expect(result.host, 'app-api.pixiv.net');
    expect(result.ttl, const Duration(seconds: 60));
    // Wire-level check: a proper RFC 8484 POST.
    final wire = server.requests.single;
    expect(wire.method, 'POST');
    expect(wire.headers['content-type'], 'application/dns-message');
    expect(wire.url.host, '1.1.1.1');
    expect(wire.url.path, '/dns-query');
    final query = decodeResponse(wire.bodyBytes);
    expect(query.question?.name, 'app-api.pixiv.net');
    expect(query.question?.type, 1);
  });

  test('TTL is clamped to the configured bounds', () async {
    final tiny = _FakeDohServer(address: '1.1.1.1')..ttl = 1;
    final huge = _FakeDohServer(address: '1.1.1.1')..ttl = 3600 * 24 * 30;
    await _expectTtl(tiny, const Duration(seconds: 5));
    await _expectTtl(huge, const Duration(minutes: 10));
  });

  test('fails over to the next endpoint in order', () async {
    final broken = _FakeDohServer(address: '1.1.1.1', statusCode: 503);
    final healthy = _FakeDohServer(address: '8.8.8.8');
    final client = _FakeClient([broken, healthy]);
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
      client: client,
    );
    addTearDown(resolver.dispose);

    final result = await resolver.resolve(
      'app-api.pixiv.net',
      revision: _revision,
    );
    expect(result.addresses.single.address, healthy.ip.address);
    expect(broken.requests, hasLength(1));
    // The failing endpoint is remembered and temporarily skipped.
    final again = await resolver.resolve('i.pximg.net', revision: _revision);
    expect(again.addresses.single.address, healthy.ip.address);
    expect(broken.requests, hasLength(1));
    expect(healthy.requests, hasLength(2));
  });

  test('all endpoints down raises SecureResolutionException', () async {
    final client = _FakeClient([
      _FakeDohServer(address: '1.1.1.1', statusCode: 500),
      _FakeDohServer(address: '8.8.8.8', statusCode: 500),
    ]);
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
      client: client,
    );
    addTearDown(resolver.dispose);

    await expectLater(
      resolver.resolve('app-api.pixiv.net', revision: _revision),
      throwsA(isA<SecureResolutionException>()),
    );
  });

  test('non-OK rcode is rejected as a resolution failure', () async {
    final nxdomain = _FakeDohServer(address: '1.1.1.1', rcode: 3);
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query'],
      client: _FakeClient([nxdomain]),
    );
    addTearDown(resolver.dispose);

    await expectLater(
      resolver.resolve('app-api.pixiv.net', revision: _revision),
      throwsA(isA<SecureResolutionException>()),
    );
  });

  test('cancellation aborts the query', () async {
    final server = _FakeDohServer(address: '1.1.1.1');
    final gate = Completer<void>();
    server.block = gate;
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query'],
      client: _FakeClient([server]),
    );
    addTearDown(resolver.dispose);
    final cancel = _TestCancelSignal();
    final query = resolver.resolve(
      'app-api.pixiv.net',
      revision: _revision,
      cancelSignal: cancel,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancel.cancel();
    gate.complete();
    await expectLater(query, throwsA(isA<NetworkFailureException>()));
  });

  test('unresolvable hosts are rejected before any network I/O', () async {
    final server = _FakeDohServer(address: '1.1.1.1');
    final client = _FakeClient([server]);
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query'],
      client: client,
    );
    addTearDown(resolver.dispose);

    await expectLater(
      resolver.resolve('127.0.0.1', revision: _revision),
      throwsA(isA<SecureResolutionException>()),
    );
    expect(client.requests, isEmpty);
  });

  test(
    'policy wiring: default resolver is DoH and scoped by registry',
    () async {
      final server = _FakeDohServer(address: '1.1.1.1');
      final policy = NetworkAccessPolicy(
        dohEndpoints: ['https://1.1.1.1/dns-query'],
        clientFactory: (route, canonicalHost, _) => _RouteAwareClient(route),
      );
      // Inject a scripted doh client via a custom resolver instead: the
      // policy itself uses its own DohResolver; to observe the resolver we
      // need the injected client. Use the real DohResolver with scripted
      // client through policy construction.
      await policy.dispose();
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([server]),
      );
      final scoped = NetworkAccessPolicy(resolver: resolver);
      addTearDown(scoped.dispose);

      // Any allowed Pixiv host passes through.
      final destination = scoped.registry.require(
        Uri.parse('https://app-api.pixiv.net/v1/illust/prime'),
        PixivDestinationPurpose.appApi,
      );
      final result = await scoped.resolve(destination);
      expect(result.dnsSource, DnsSource.doh);
      expect(result.addresses.single.address, server.ip.address);

      // A non-Pixiv host never reaches the resolver via the registry.
      expect(
        () => scoped.registry.require(
          Uri.parse('https://evil.example.com/'),
          PixivDestinationPurpose.appApi,
        ),
        throwsA(isA<PixivDestinationException>()),
      );
    },
  );

  test('requests time out and surface as a resolution failure', () async {
    final server = _FakeDohServer(address: '1.1.1.1')
      ..delay = const Duration(milliseconds: 200);
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query'],
      client: _FakeClient([server]),
      requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(resolver.dispose);

    await expectLater(
      resolver.resolve('app-api.pixiv.net', revision: _revision),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('oversized responses are rejected', () async {
    // A fake server that returns a body larger than the cap.
    final client = _HugeClient();
    final resolver = DohResolver(
      endpointUrls: ['https://1.1.1.1/dns-query'],
      client: client,
      maxResponseBytes: 512,
    );
    addTearDown(resolver.dispose);

    await expectLater(
      resolver.resolve('app-api.pixiv.net', revision: _revision),
      throwsA(isA<SecureResolutionException>()),
    );
  });
  test('policy default DoH endpoints map Cloudflare anycast IPs', () {
    // The bootstrap contract: default DoH endpoints are domain URLs whose
    // hostnames have static anycast IP mappings (PixEz DnsSettings.static).
    // Asserting the wiring here catches a regression where the policy stops
    // pinning DC IPs and silently re-enters polluted system-DNS resolution.
    final policy = NetworkAccessPolicy();
    addTearDown(policy.dispose);
    final resolver = policy.resolver;
    expect(resolver, isA<DohResolver>());
    final doh = resolver as DohResolver;
    // Quick reflection-free check: the effective endpoint list is the
    // Cloudflare/Google domain form (IP literals would re-enter recursion).
    // hostOverrides is a public field; assert the main host is covered.
    expect(
      doh.hostOverrides.keys,
      contains('1dot1dot1dot1.cloudflare-dns.com'),
    );
    expect(
      doh.hostOverrides['1dot1dot1dot1.cloudflare-dns.com']!.first.address,
      '104.16.248.249',
    );
  });
  group('lookupEchConfig', () {
    test('extracts ech config from an HTTPS RR answer', () async {
      final server = _FakeDohServer(address: '1.1.1.1')
        ..httpsEchRdata = _echRdata([0xfe, 0x0d, 1, 2, 3])
        ..httpsTtl = 120;
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([server]),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );

      expect(result.echConfig, [0xfe, 0x0d, 1, 2, 3]);
      expect(result.ttl, const Duration(seconds: 120));
      final wire = server.requests.single;
      final query = decodeResponse(wire.bodyBytes);
      expect(query.question?.name, 'cloudflare-ech.com');
      expect(query.question?.type, 65);
    });

    test('TTL is clamped for ECH config like addresses', () async {
      final huge = _FakeDohServer(address: '1.1.1.1')
        ..httpsEchRdata = _echRdata([1])
        ..httpsTtl = 3600 * 24 * 30;
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([huge]),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );
      expect(result.ttl, const Duration(minutes: 10));
    });

    test('caches ECH config until TTL and returns defensive copies', () async {
      final base = DateTime(2026, 8, 31, 12);
      var now = base;
      final server = _FakeDohServer(address: '1.1.1.1')
        ..httpsEchRdata = _echRdata([1, 2, 3])
        ..httpsTtl = 30;
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([server]),
        clock: () => now,
      );
      addTearDown(resolver.dispose);

      final first = await resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );
      first.echConfig[0] = 99;
      final cached = await resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );

      expect(cached.echConfig, [1, 2, 3]);
      expect(server.requests, hasLength(1));

      now = base.add(const Duration(seconds: 31));
      await resolver.lookupEchConfig('cloudflare-ech.com', revision: _revision);
      expect(server.requests, hasLength(2));
    });

    test('revision change invalidates ECH config cache', () async {
      final server = _FakeDohServer(address: '1.1.1.1')
        ..httpsEchRdata = _echRdata([1, 2, 3]);
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([server]),
      );
      addTearDown(resolver.dispose);

      await resolver.lookupEchConfig('cloudflare-ech.com', revision: _revision);
      await resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: const NetworkRevision(8, networkIdentity: 'cellular'),
      );

      expect(server.requests, hasLength(2));
    });

    test('concurrent uncancelled ECH lookups share one wire query', () async {
      final gate = Completer<void>();
      final server = _FakeDohServer(address: '1.1.1.1')
        ..httpsEchRdata = _echRdata([1, 2, 3])
        ..block = gate;
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([server]),
      );
      addTearDown(resolver.dispose);

      final first = resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );
      final second = resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );
      await Future<void>.delayed(Duration.zero);
      expect(server.requests, hasLength(1));

      gate.complete();
      final results = await Future.wait([first, second]);
      expect(results[0].echConfig, results[1].echConfig);
      expect(server.requests, hasLength(1));
    });

    test(
      'a successful cancellable ECH lookup still populates the cache',
      () async {
        final server = _FakeDohServer(address: '1.1.1.1')
          ..httpsEchRdata = _echRdata([1, 2, 3]);
        final resolver = DohResolver(
          endpointUrls: ['https://1.1.1.1/dns-query'],
          client: _FakeClient([server]),
        );
        addTearDown(resolver.dispose);

        await resolver.lookupEchConfig(
          'cloudflare-ech.com',
          revision: _revision,
          cancelSignal: _TestCancelSignal(),
        );
        await resolver.lookupEchConfig(
          'cloudflare-ech.com',
          revision: _revision,
        );

        expect(server.requests, hasLength(1));
      },
    );

    test(
      'no ech SvcParam → SecureResolutionException (no silent fallback)',
      () async {
        final server = _FakeDohServer(address: '1.1.1.1'); // httpsEchRdata null
        final resolver = DohResolver(
          endpointUrls: ['https://1.1.1.1/dns-query'],
          client: _FakeClient([server]),
        );
        addTearDown(resolver.dispose);

        await expectLater(
          resolver.lookupEchConfig('cloudflare-ech.com', revision: _revision),
          throwsA(isA<SecureResolutionException>()),
        );
      },
    );

    test('endpoint failover applies to ECH lookups', () async {
      final broken = _FakeDohServer(address: '1.1.1.1', statusCode: 503);
      final healthy = _FakeDohServer(address: '8.8.8.8')
        ..httpsEchRdata = _echRdata([9, 9]);
      final resolver = DohResolver(
        endpointUrls: [
          'https://1.1.1.1/dns-query',
          'https://8.8.8.8/dns-query',
        ],
        client: _FakeClient([broken, healthy]),
      );
      addTearDown(resolver.dispose);

      final result = await resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
      );
      expect(result.echConfig, [9, 9]);
      expect(broken.requests, hasLength(1));
    });

    test('cancellation aborts the ECH lookup', () async {
      final server = _FakeDohServer(address: '1.1.1.1')
        ..httpsEchRdata = _echRdata([1]);
      final gate = Completer<void>();
      server.block = gate;
      final resolver = DohResolver(
        endpointUrls: ['https://1.1.1.1/dns-query'],
        client: _FakeClient([server]),
      );
      addTearDown(resolver.dispose);
      final cancel = _TestCancelSignal();
      final query = resolver.lookupEchConfig(
        'cloudflare-ech.com',
        revision: _revision,
        cancelSignal: cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel.cancel();
      await expectLater(
        query,
        throwsA(
          isA<NetworkFailureException>().having(
            (e) => e.kind,
            'kind',
            NetworkFailureKind.cancelled,
          ),
        ),
      );
      server.block = null;
      gate.complete();
      await Future<void>.delayed(Duration.zero);

      await resolver.lookupEchConfig('cloudflare-ech.com', revision: _revision);
      expect(
        server.requests,
        hasLength(2),
        reason: 'a cancelled lookup must not populate the cache',
      );
    });
  });
}

Future<void> _expectTtl(_FakeDohServer server, Duration expected) async {
  final resolver = DohResolver(
    endpointUrls: ['https://1.1.1.1/dns-query'],
    client: _FakeClient([server]),
  );
  addTearDown(resolver.dispose);
  final result = await resolver.resolve(
    'app-api.pixiv.net',
    revision: _revision,
  );
  expect(result.ttl, expected);
}

class _TestCancelSignal implements NetworkCancelSignal {
  final _completer = Completer<void>();
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancel => _completer.future;
}

class _RouteAwareClient extends http.BaseClient {
  _RouteAwareClient(this.route);

  final NetworkRoute route;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('unexpected real send in policy test');
  }
}

class _HugeClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(List.filled(4096, 0xab)),
      200,
      request: request,
    );
  }
}
