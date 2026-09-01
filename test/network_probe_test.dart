import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_probe.dart';
import 'package:pixiv_func/core/network/compat/secure_resolver.dart';

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

final _v4 = [InternetAddress('1.1.1.1'), InternetAddress('2.2.2.2')];
final _v4b = [InternetAddress('9.9.9.9')];

void main() {
  test('all layers reachable -> allReachable', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'ok',
      httpResult: 'ok',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.allReachable);
    expect(report.steps.every((s) => s.ok), isTrue);
    expect(report.toCopyableText(), contains('conclusion: allReachable'));
    expect(report.toCopyableText(), contains('system-dns: ok'));
    expect(report.toCopyableText(), contains('tls: ok'));
  });

  test('system DNS disagrees with DoH -> dnsPolluted', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4b,
      tcpResult: 'ok',
      tlsResult: 'ok',
      httpResult: 'ok',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.dnsPolluted);
    expect(report.dnsDisagrees, isTrue);
  });

  test('DNS discrepancy does not hide a working ECH transport', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4b,
      tcpResult: 'ok',
      tlsResult: 'handshake reset',
      httpResult: 'not reached',
      echConfigResult: [1, 2, 3],
    ).run();

    expect(report.dnsDisagrees, isTrue);
    expect(report.conclusion, NetworkProbeConclusion.echAvailable);
    expect(report.toCopyableText(), contains('dns-disagrees: true'));
  });

  test('DoH subset of system RRset is NOT pollution (CDN rotation)', () async {
    // s.pximg.net real-world case: system DNS returns the full RRset
    // (10 x 210.140.139.x), DoH answers one of them
    // (210.140.139.134). Both are the same CDN range — only the
    // rotation differs. Set inequality MUST NOT be classified as
    // pollution, otherwise the probe lies about a healthy host.
    final shared = InternetAddress('210.140.139.134');
    final report = await _Harness(
      systemAddresses: [
        InternetAddress('210.140.139.155'),
        shared,
        InternetAddress('210.140.139.168'),
      ],
      dohAddresses: [shared],
      tcpResult: 'ok',
      tlsResult: 'ok',
      httpResult: 'ok',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.allReachable);
  });

  test('TCP fails after successful DoH -> ipBlackholed', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'connect refused',
      tlsResult: 'not reached',
      httpResult: 'not reached',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.ipBlackholed);
  });

  test('TCP ok but real-SNI TLS handshake fails -> sniBlocked', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'handshake reset',
      httpResult: 'not reached',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.sniBlocked);
  });

  test('TLS ok but minimal request fails -> appLayer', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'ok',
      httpResult: 'HTTP 403',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.appLayer);
  });

  test('DoH unavailable and no candidate -> inconclusive', () async {
    final report = await _Harness(
      systemAddresses: const [],
      dohAddresses: const [],
      tcpResult: 'no candidate',
      tlsResult: 'no candidate',
      httpResult: 'no candidate',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.inconclusive);
  });

  test('report is copyable and includes the intended lines', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'handshake reset',
      httpResult: 'not reached',
    ).run();
    final text = report.toCopyableText();
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

  test('real-SNI fails but ECH available -> echAvailable', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'handshake reset',
      httpResult: 'ok',
      echConfigResult: [1, 2, 3],
      noSniResult: 'fail',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.echAvailable);
    expect(report.steps.map((s) => s.name), contains('ech'));
  });

  test(
    'ECH HTTP 404/403 still proves the ECH transport reached the server',
    () async {
      for (final status in [404, 403]) {
        final report = await NetworkProbe.run(
          host: 'app-api.pixiv.net',
          purpose: PixivDestinationPurpose.appApi,
          registry: PixivDestinationRegistry(),
          dohResolver: _ScriptedResolver(_v4),
          revision: const NetworkRevision(0),
          systemLookup: (host) async => _v4,
          tcpConnect: (a, p) async {},
          tlsHandshake: (a, p, h) async => throw HandshakeException('reset'),
          minimalRequest: (uri) async => const HttpProbeResponse(404),
          echConfigLookup: () async => EchConfigResult(
            echConfig: Uint8List.fromList([1, 2, 3]),
            ttl: const Duration(seconds: 30),
            frontAddresses: [InternetAddress('104.18.10.118')],
          ),
          echRequest: (uri, address, config) async => HttpProbeResponse(status),
          timeoutPerLayer: const Duration(seconds: 2),
        );

        expect(report.conclusion, NetworkProbeConclusion.echAvailable);
        expect(
          report.steps.firstWhere((s) => s.name == 'ech').detail,
          contains('HTTP $status'),
        );
      }
    },
  );

  test('ECH config missing -> falls to noSni when empty-SNI ok', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'handshake reset',
      httpResult: 'ok',
      echConfigResult: null, // config lookup failed
      noSniResult: 'ok',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.noSniAvailable);
  });

  test('both ECH and empty-SNI unavailable -> sniBlocked', () async {
    final report = await _Harness(
      systemAddresses: _v4,
      dohAddresses: _v4,
      tcpResult: 'ok',
      tlsResult: 'handshake reset',
      httpResult: 'ok',
      echConfigResult: 'ech rejected',
      noSniResult: 'no-sni rejected',
    ).run();
    expect(report.conclusion, NetworkProbeConclusion.sniBlocked);
  });

  test('HTTP 421 with empty SNI -> layer fails (tier unusable)', () async {
    final resolver = _ScriptedResolver(_v4);
    final report = await NetworkProbe.run(
      host: 'i.pximg.net',
      purpose: PixivDestinationPurpose.image,
      registry: PixivDestinationRegistry(),
      dohResolver: resolver,
      revision: const NetworkRevision(0),
      systemLookup: (host) async => _v4,
      tcpConnect: (a, p) async {},
      tlsHandshake: (a, p, h) async => throw HandshakeException('reset'),
      minimalRequest: (uri) async => const HttpProbeResponse(200),
      echConfigLookup: () async => null,
      httpNoSniRequest: (uri, address) async => const HttpProbeResponse(421),
      timeoutPerLayer: const Duration(seconds: 2),
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
      final report = await NetworkProbe.run(
        host: 'app-api.pixiv.net',
        purpose: PixivDestinationPurpose.appApi,
        registry: PixivDestinationRegistry(),
        dohResolver: _ScriptedResolver(_v4),
        revision: const NetworkRevision(0),
        systemLookup: (host) async => _v4,
        tcpConnect: (a, p) async {},
        tlsHandshake: (a, p, h) async => throw HandshakeException('reset'),
        minimalRequest: (uri) async => const HttpProbeResponse(200),
        echConfigLookup: () async => EchConfigResult(
          echConfig: Uint8List.fromList([1, 2, 3]),
          ttl: const Duration(seconds: 30),
        ),
        timeoutPerLayer: const Duration(seconds: 2),
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
    final report = await NetworkProbe.run(
      host: 'app-api.pixiv.net',
      purpose: PixivDestinationPurpose.appApi,
      registry: PixivDestinationRegistry(),
      dohResolver: _ScriptedResolver(_v4),
      revision: const NetworkRevision(0),
      systemLookup: (host) async => _v4,
      tcpConnect: (a, p) async {},
      tlsHandshake: (a, p, h) async => throw HandshakeException('reset'),
      minimalRequest: (uri) async => const HttpProbeResponse(200),
      echConfigLookup: () async => EchConfigResult(
        echConfig: Uint8List(0),
        ttl: const Duration(seconds: 30),
      ),
      echRequest: (uri, address, echConfig) async {
        // Must never be reached.
        fail('echRequest must not be called with an empty config');
      },
      timeoutPerLayer: const Duration(seconds: 2),
    );
    final ech = report.steps.firstWhere((s) => s.name == 'ech');
    expect(ech.ok, isFalse);
    expect(ech.detail, contains('ECH config list is empty'));
  });

  test('lookup returns unexpected type -> ech layer FAILS', () async {
    final report = await NetworkProbe.run(
      host: 'app-api.pixiv.net',
      purpose: PixivDestinationPurpose.appApi,
      registry: PixivDestinationRegistry(),
      dohResolver: _ScriptedResolver(_v4),
      revision: const NetworkRevision(0),
      systemLookup: (host) async => _v4,
      tcpConnect: (a, p) async {},
      tlsHandshake: (a, p, h) async => throw HandshakeException('reset'),
      minimalRequest: (uri) async => const HttpProbeResponse(200),
      echConfigLookup: () async => 'not-a-result',
      echRequest: (uri, address, echConfig) async {
        fail('echRequest must not be called with an unexpected type');
      },
      timeoutPerLayer: const Duration(seconds: 2),
    );
    final ech = report.steps.firstWhere((s) => s.name == 'ech');
    expect(ech.ok, isFalse);
    expect(ech.detail, contains('unexpected type'));
  });
}
