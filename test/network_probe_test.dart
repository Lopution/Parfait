import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_probe.dart';
import 'package:parfait/core/network/compat/secure_resolver.dart';

/// Deterministic offline harness: every injected layer is scripted, so the
/// classification matrix (design §探测页) is pinned without any network.
///
/// `systemResult` / `dohResult` are address lists; `tcpResult`,
/// `tlsResult`, `httpResult` are 'ok' or a failure message.
class _Harness {
  _Harness({
    required this.systemAddresses,
    required this.dohAddresses,
    required this.tcpResult,
    required this.tlsResult,
    required this.httpResult,
    this.echConfigResult = _unset,
    this.noSniResult = _unset,
  });

  static const _unset = Object();

  final List<InternetAddress> systemAddresses;
  final List<InternetAddress> dohAddresses;
  final String tcpResult;
  final String tlsResult;
  final String httpResult;

  /// `Object?` sentinel: null = lookup failed (no config); list = ECH config
  /// available and ECH request ok; string = thrown error message.
  final Object? echConfigResult;
  final Object? noSniResult;

  static bool _ok(String result) => result == 'ok';

  Future<NetworkProbeReport> run() {
    final resolver = _ScriptedResolver(dohAddresses);
    final hasEch = !identical(echConfigResult, _unset);
    final hasNoSni = !identical(noSniResult, _unset);
    return NetworkProbe.run(
      host: 'app-api.pixiv.net',
      purpose: PixivDestinationPurpose.appApi,
      registry: PixivDestinationRegistry(),
      dohResolver: resolver,
      revision: const NetworkRevision(0),
      systemLookup: (host) async => systemAddresses,
      tcpConnect: (address, port) async {
        if (!_ok(tcpResult)) throw SocketException(tcpResult);
      },
      tlsHandshake: (address, port, host) async {
        if (!_ok(tlsResult)) throw HandshakeException(tlsResult);
      },
      minimalRequest: (uri) async {
        if (!_ok(httpResult)) throw HttpException(httpResult);
        return const HttpProbeResponse(200);
      },
      echConfigLookup: hasEch
          ? () async {
              final value = echConfigResult;
              if (value is String && !_ok(value)) {
                throw HandshakeException(value);
              }
              if (value == null) return null;
              return EchConfigResult(
                echConfig: Uint8List.fromList([1, 2, 3]),
                ttl: const Duration(seconds: 30),
                frontAddresses: [InternetAddress('104.18.10.118')],
              );
            }
          : null,
      echRequest: hasEch
          ? (uri, address, echConfig) async {
              final value = echConfigResult;
              if (value is String && !_ok(value)) {
                throw HandshakeException(value);
              }
              return const HttpProbeResponse(200);
            }
          : null,
      noSniHandshake: hasNoSni
          ? (address, port) async {
              final value = noSniResult;
              if (value is String && !_ok(value)) {
                throw HandshakeException(value);
              }
              return;
            }
          : null,
      timeoutPerLayer: const Duration(seconds: 2),
    );
  }
}

class _ScriptedResolver implements SecureResolver {
  _ScriptedResolver(this.addresses);

  final List<InternetAddress> addresses;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    if (addresses.isEmpty) {
      throw const SecureResolutionException('probe doh failed');
    }
    return ResolvedHost(
      host: host,
      addresses: addresses,
      dnsSource: DnsSource.doh,
      revision: revision,
      ttl: const Duration(seconds: 30),
    );
  }

  @override
  Future<void> dispose() async {}
}

typedef _C = NetworkProbeConclusion;

/// A harness whose TCP, TLS and HTTP layers answer as `tcp|tls|http`
/// says; `-` is a layer never reached.
_Harness _probe(
  List<InternetAddress> system,
  List<InternetAddress> doh,
  String layers, [
  Object? ech = _Harness._unset,
  Object? noSni = _Harness._unset,
]) {
  final [tcp, tls, http] = [
    for (final layer in layers.split('|')) layer == '-' ? 'not reached' : layer,
  ];
  return _Harness(
    systemAddresses: system,
    dohAddresses: doh,
    tcpResult: tcp,
    tlsResult: tls,
    httpResult: http,
    echConfigResult: ech,
    noSniResult: noSni,
  );
}

final _v4 = [InternetAddress('1.1.1.1'), InternetAddress('2.2.2.2')];
final _v4b = [InternetAddress('9.9.9.9')];

void main() {
  test('all layers reachable -> allReachable', () async {
    final report = await _probe(_v4, _v4, 'ok|ok|ok').run();
    expect(report.conclusion, NetworkProbeConclusion.allReachable);
    expect(report.steps.every((s) => s.ok), isTrue);
    expect(report.toCopyableText(), contains('conclusion: allReachable'));
    expect(report.toCopyableText(), contains('system-dns: ok'));
    expect(report.toCopyableText(), contains('tls: ok'));
    // P-NET timing: each layer carries its wall-clock duration and the
    // total run time is exported; the probe never adds extra requests.
    expect(
      report.steps.every((step) => step.duration >= Duration.zero),
      isTrue,
    );
    expect(report.toCopyableText(), contains('total '));
    expect(report.totalDuration >= Duration.zero, isTrue);
  });

  test('each failing layer names its conclusion', () async {
    // s.pximg.net real-world case: system DNS returns the full RRset, DoH
    // answers one of them. Only the rotation differs; a subset MUST NOT
    // read as pollution, or the probe lies about a healthy host.
    final shared = InternetAddress('210.140.139.134');
    final rrset = [InternetAddress('210.140.139.155'), shared];
    const none = <InternetAddress>[];
    for (final (probe, conclusion) in [
      (_probe(_v4, _v4b, 'ok|ok|ok'), _C.dnsPolluted),
      (_probe(rrset, [shared], 'ok|ok|ok'), _C.allReachable),
      (_probe(_v4, _v4, 'connect refused|-|-'), _C.ipBlackholed),
      (_probe(_v4, _v4, 'ok|handshake reset|-'), _C.sniBlocked),
      (_probe(_v4, _v4, 'ok|ok|HTTP 403'), _C.appLayer),
      (_probe(none, none, 'no candidate|-|-'), _C.inconclusive),
      // Real SNI fails: ECH, else empty SNI, else blocked.
      (_probe(_v4, _v4, 'ok|reset|ok', [1, 2, 3], 'fail'), _C.echAvailable),
      (_probe(_v4, _v4, 'ok|reset|ok', null, 'ok'), _C.noSniAvailable),
      (_probe(_v4, _v4, 'ok|reset|ok', 'rejected', 'rejected'), _C.sniBlocked),
    ]) {
      final report = await probe.run();
      expect(report.conclusion, conclusion);
      if (conclusion == _C.dnsPolluted) expect(report.dnsDisagrees, isTrue);
      if (conclusion == _C.echAvailable) {
        expect(report.steps.map((s) => s.name), contains('ech'));
      }
    }
  });

  test('DNS discrepancy does not hide a working ECH transport', () async {
    final report = await _probe(_v4, _v4b, 'ok|handshake reset|-', [
      1,
      2,
      3,
    ]).run();

    expect(report.dnsDisagrees, isTrue);
    expect(report.conclusion, NetworkProbeConclusion.echAvailable);
    expect(report.toCopyableText(), contains('dns-disagrees: true'));
  });

  test('report is copyable and includes the intended lines', () async {
    final report = await _probe(_v4, _v4, 'ok|handshake reset|-').run();
    final environment = NetworkProbeEnvironment(
      probedAtUtc: DateTime.utc(2026, 9, 8, 4, 30),
      appVersion: '0.1.0+1',
      operatingSystem: 'linux',
      operatingSystemVersion: '6.6.test',
      networkMode: 'automatic',
      dohEndpoints: [
        'https://dns.alidns.com/dns-query',
        'https://1dot1dot1dot1.cloudflare-dns.com/dns-query',
      ],
      echFrontHost: 'cloudflare-ech.com',
    );
    final text = report.copyWith(environment: environment).toCopyableText();
    expect(text, contains('env: 2026-09-08T04:30:00.000Z'));
    expect(text, contains('app-version: 0.1.0+1'));
    expect(text, contains('os: linux 6.6.test'));
    expect(text, contains('network-mode: automatic'));
    expect(
      text,
      contains(
        'doh: https://dns.alidns.com/dns-query, '
        'https://1dot1dot1dot1.cloudflare-dns.com/dns-query',
      ),
    );
    expect(text, contains('ech-front: cloudflare-ech.com'));
    expect(text, contains('NetworkProbe app-api.pixiv.net (appApi)'));
    expect(text, contains('conclusion: sniBlocked'));
    expect(text, contains('tcp: ok'));
    expect(text, contains('tls: FAILED'));
  });

  test('probe serves only registry-allowed Pixiv hosts', () async {
    await expectLater(
      () => NetworkProbe.run(
        host: 'evil.example.com',
        purpose: PixivDestinationPurpose.appApi,
        registry: PixivDestinationRegistry(),
        dohResolver: _ScriptedResolver(_v4),
        revision: const NetworkRevision(0),
        tcpConnect: (a, p) async {},
        tlsHandshake: (a, p, h) async {},
        minimalRequest: (uri) async => const HttpProbeResponse(200),
      ),
      throwsA(isA<PixivDestinationException>()),
    );
  });

  test(
    'ECH HTTP 404/403 still proves the ECH transport reached the server',
    () async {
      for (final status in [404, 403]) {
        final report = await _sniResetProbe(
          minimalStatus: 404,
          echConfigLookup: () async => EchConfigResult(
            echConfig: Uint8List.fromList([1, 2, 3]),
            ttl: const Duration(seconds: 30),
            frontAddresses: [InternetAddress('104.18.10.118')],
          ),
          echRequest: (uri, address, config) async => HttpProbeResponse(status),
        );

        expect(report.conclusion, NetworkProbeConclusion.echAvailable);
        expect(
          report.steps.firstWhere((s) => s.name == 'ech').detail,
          contains('HTTP $status'),
        );
      }
    },
  );

  test('HTTP 421 with empty SNI -> layer fails (tier unusable)', () async {
    final report = await _sniResetProbe(
      host: 'i.pximg.net',
      purpose: PixivDestinationPurpose.image,
      echConfigLookup: () async => null,
      httpNoSniRequest: (uri, address) async => const HttpProbeResponse(421),
    );
    final noSni = report.steps.firstWhere((s) => s.name == 'no-sni');
    expect(noSni.ok, isFalse);
    expect(noSni.detail, contains('421'));
    expect(report.conclusion, NetworkProbeConclusion.sniBlocked);
  });

  test(
    'config ok but no ECH transport -> ech layer FAILS (no plain-TLS fallback)',
    () async {
      // Regression for the false positive: an earlier wiring fell back to the
      // plain-TLS minimal request when no ECH prober was injected, measured a
      // non-ECH connection and reported `ech: ok`. A config without a
      // transport cannot be measured; the layer must fail, never pretend.
      final report = await _sniResetProbe(
        echConfigLookup: () async => EchConfigResult(
          echConfig: Uint8List.fromList([1, 2, 3]),
          ttl: const Duration(seconds: 30),
        ),
      );
      final ech = report.steps.firstWhere((s) => s.name == 'ech');
      expect(ech.ok, isFalse);
      expect(ech.detail, contains('no ECH transport prober configured'));
      expect(report.conclusion, NetworkProbeConclusion.sniBlocked);
    },
  );

  test('empty ECH config list -> ech layer FAILS', () async {
    // An empty config list must be a hard failure: rustls with an empty ECH
    // list would send a plain ClientHello, and the layer would measure
    // plain TLS while claiming ECH works.
    final report = await _sniResetProbe(
      echConfigLookup: () async => EchConfigResult(
        echConfig: Uint8List(0),
        ttl: const Duration(seconds: 30),
      ),
      echRequest: (uri, address, echConfig) async {
        // Must never be reached.
        fail('echRequest must not be called with an empty config');
      },
    );
    final ech = report.steps.firstWhere((s) => s.name == 'ech');
    expect(ech.ok, isFalse);
    expect(ech.detail, contains('ECH config list is empty'));
  });

  test('lookup returns unexpected type -> ech layer FAILS', () async {
    final report = await _sniResetProbe(
      echConfigLookup: () async => 'not-a-result',
      echRequest: (uri, address, echConfig) async {
        fail('echRequest must not be called with an unexpected type');
      },
    );
    final ech = report.steps.firstWhere((s) => s.name == 'ech');
    expect(ech.ok, isFalse);
    expect(ech.detail, contains('unexpected type'));
  });
}

/// A probe whose real-SNI handshake is reset, so the ECH and empty-SNI layers
/// the caller wires decide the conclusion.
Future<NetworkProbeReport> _sniResetProbe({
  String host = 'app-api.pixiv.net',
  PixivDestinationPurpose purpose = PixivDestinationPurpose.appApi,
  int minimalStatus = 200,
  Future<Object?> Function()? echConfigLookup,
  Future<HttpProbeResponse> Function(
    Uri uri,
    InternetAddress address,
    Object? echConfig,
  )?
  echRequest,
  Future<HttpProbeResponse> Function(Uri uri, InternetAddress address)?
  httpNoSniRequest,
}) => NetworkProbe.run(
  host: host,
  purpose: purpose,
  registry: PixivDestinationRegistry(),
  dohResolver: _ScriptedResolver(_v4),
  revision: const NetworkRevision(0),
  systemLookup: (host) async => _v4,
  tcpConnect: (a, p) async {},
  tlsHandshake: (a, p, h) async => throw HandshakeException('reset'),
  minimalRequest: (uri) async => HttpProbeResponse(minimalStatus),
  echConfigLookup: echConfigLookup,
  echRequest: echRequest,
  httpNoSniRequest: httpNoSniRequest,
  timeoutPerLayer: const Duration(seconds: 2),
);
