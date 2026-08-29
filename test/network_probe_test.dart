import 'dart:io';

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
  });

  final List<InternetAddress> systemAddresses;
  final List<InternetAddress> dohAddresses;
  final String tcpResult;
  final String tlsResult;
  final String httpResult;

  static bool _ok(String result) => result == 'ok';

  Future<NetworkProbeReport> run() {
    final resolver = _ScriptedResolver(dohAddresses);
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
}