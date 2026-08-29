import 'dart:async';
import 'dart:io';

import 'network_contracts.dart';
import 'secure_resolver.dart';

/// Layered connectivity probe for one Pixiv destination host.
///
/// The probe is the *measuring instrument* that decides whether Phase 2
/// (native SNI-omitting transport) must exist. Each layer is falsifiable on
/// its own, and the combination maps deterministically to a conclusion:
///
/// | observation | conclusion |
/// |---|---|
/// | system DNS != DoH addresses | DNS pollution — Phase 1 (DoH) suffices |
/// | DoH has answers but TCP fails | IP blackholing — no client-side fix |
/// | TCP ok but TLS handshake (real SNI) fails | SNI blocked — Phase 2 needed |
/// | TLS ok but minimal request fails | app-layer issue, unrelated to blocking |
///
/// All I/O is injected ([socketFactory], [systemLookup], [resolver], and the
/// transport for the minimal request), so the whole matrix is unit-testable
/// offline; the real implementation defaults to the platform primitives.
abstract final class NetworkProbe {
  /// Namespace constant for the probe HTTP request path; the probe never
  /// sends credentials or cookies.
  static const probePath = '/v1/illust/prime';

  /// Runs every layer for [host] and returns a step-by-step report.
  ///
  /// [purpose] selects the registry scope so the probe cannot be pointed at
  /// arbitrary hosts; [timeoutPerLayer] bounds each network step.
  static Future<NetworkProbeReport> run({
    required String host,
    required PixivDestinationPurpose purpose,
    required PixivDestinationRegistry registry,
    required SecureResolver dohResolver,
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
    Future<List<InternetAddress>> Function(String host)? systemLookup,
    Future<void> Function(InternetAddress address, int port)? tcpConnect,
    Future<void> Function(InternetAddress address, int port, String host)?
    tlsHandshake,
    Future<HttpProbeResponse> Function(Uri uri)? minimalRequest,
    Duration timeoutPerLayer = const Duration(seconds: 6),
  }) {
    final destination = registry.require(
      Uri.parse('https://$host$probePath'),
      purpose,
    );
    return _runner(
      destination: destination,
      dohResolver: dohResolver,
      revision: revision,
      cancelSignal: cancelSignal,
      systemLookup: systemLookup ?? InternetAddress.lookup,
      tcpConnect: tcpConnect ?? _defaultTcpConnect,
      tlsHandshake: tlsHandshake ?? _defaultTlsHandshake,
      minimalRequest: minimalRequest ?? _defaultMinimalRequest,
      timeoutPerLayer: timeoutPerLayer,
    );
  }

  static Future<NetworkProbeReport> _runner({
    required PixivDestination destination,
    required SecureResolver dohResolver,
    required NetworkRevision revision,
    required NetworkCancelSignal? cancelSignal,
    required Future<List<InternetAddress>> Function(String host) systemLookup,
    required Future<void> Function(InternetAddress address, int port)
    tcpConnect,
    required Future<void> Function(InternetAddress address, int port, String host)
    tlsHandshake,
    required Future<HttpProbeResponse> Function(Uri uri) minimalRequest,
    required Duration timeoutPerLayer,
  }) async {
    final host = destination.canonicalHost;
    final steps = <NetworkProbeStep>[];
    final rawSteps = <_ProbeStep>[];
    String? firstError;

    // Layer 1: system DNS.
    final systemDns = await _step('system-dns', () async {
      final addresses = await systemLookup(host).timeout(timeoutPerLayer);
      final safe = addresses.where(isPublicNetworkAddress).toList();
      if (safe.isEmpty) {
        throw const NetworkProbeLayerException('no public address');
      }
      return _ProbeValue(
        '${safe.length} public address(es): '
            '${safe.map((a) => a.address).join(', ')}',
        addresses: safe,
      );
    });
    steps.add(systemDns.step);
    rawSteps.add(systemDns);
    if (!systemDns.step.ok) firstError ??= systemDns.step.detail;

    // Layer 2: DoH.
    final doh = await _step('doh', () async {
      final resolved = await dohResolver.resolve(
        host,
        revision: revision,
        cancelSignal: cancelSignal,
      );
      final safe = resolved.addresses
          .where(isPublicNetworkAddress)
          .toList(growable: false);
      if (safe.isEmpty) {
        throw const NetworkProbeLayerException('no public address');
      }
      return _ProbeValue(
        '${safe.length} public address(es): '
            '${safe.map((a) => a.address).join(', ')} '
            '(source ${resolved.dnsSource.name})',
        addresses: safe,
      );
    });
    steps.add(doh.step);
    rawSteps.add(doh);
    if (!doh.step.ok) firstError ??= doh.step.detail;

    final systemAddresses = _addressesOf(systemDns);
    final dohAddresses = _addressesOf(doh);
    final dnsDisagrees = systemAddresses != null &&
        dohAddresses != null &&
        !_sameAddressSets(systemAddresses, dohAddresses);

    // Layer 3: TCP to the first DoH address (or system one).
    final tcpTarget = dohAddresses?.first ?? systemAddresses?.first;
    final tcp = await _step('tcp', () async {
      if (tcpTarget == null) {
        throw const NetworkProbeLayerException('no candidate address');
      }
      await tcpConnect(tcpTarget, 443).timeout(timeoutPerLayer);
      return 'connected to ${tcpTarget.address}';
    });
    steps.add(tcp.step);
    if (!tcp.step.ok) firstError ??= tcp.step.detail;

    // Layer 4: TLS handshake with the REAL SNI (hostname).
    final tls = await _step('tls', () async {
      if (tcpTarget == null) {
        throw const NetworkProbeLayerException('no candidate address');
      }
      await tlsHandshake(tcpTarget, 443, host).timeout(timeoutPerLayer);
      return 'handshake ok with SNI $host';
    });
    steps.add(tls.step);
    if (!tls.step.ok) firstError ??= tls.step.detail;

    // Layer 5: minimal real request (no credentials).
    final http = await _step('http', () async {
      final uri = Uri.parse('https://$host$probePath');
      final response = await minimalRequest(uri).timeout(timeoutPerLayer);
      return 'HTTP ${response.statusCode}';
    });
    steps.add(http.step);
    if (!http.step.ok) firstError ??= http.step.detail;

    return NetworkProbeReport(
      host: host,
      purpose: destination.purpose,
      steps: steps,
      conclusion: _classify(steps, dnsDisagrees),
      firstError: firstError,
    );
  }

  /// DNS answers from two independent resolvers are usually NOT set-equal
  /// even when both are clean: the system resolver returns the full RRset
  /// (e.g. 10 IPs for s.pximg.net) while DoH answers a single address, and
  /// each query carries a different rotation. Treating set inequality as
  /// pollution therefore produces false positives on CDN-backed hosts.
  ///
  /// A discrepancy is only evidence of pollution when the two sources
  /// share NO address at all (system says `65.49.26.99`, DoH says
  /// `199.59.148.20` — pixiv's real ranges appear in neither).
  static bool _sameAddressSets(
    List<InternetAddress> a,
    List<InternetAddress> b,
  ) {
    final aSet = a.map((x) => x.address).toSet();
    final bSet = b.map((x) => x.address).toSet();
    return aSet.intersection(bSet).isNotEmpty;
  }

  static NetworkProbeConclusion _classify(
    List<NetworkProbeStep> steps,
    bool dnsDisagrees,
  ) {
    NetworkProbeStep? byName(String name) =>
        steps.where((s) => s.name == name).firstOrNull;

    final systemDns = byName('system-dns');
    final doh = byName('doh');
    final tcp = byName('tcp');
    final tls = byName('tls');
    final http = byName('http');

    final systemDnsOk = systemDns?.ok ?? false;
    final dohOk = doh?.ok ?? false;
    final systemDnsAddresses =
        systemDns?.detail.contains('address(es):') ?? false;
    final dohAddresses = doh?.detail.contains('address(es):') ?? false;

    if (dnsDisagrees) {
      return NetworkProbeConclusion.dnsPolluted;
    }
    final hadCandidate = (systemDnsOk && systemDnsAddresses) ||
        (dohOk && dohAddresses);
    if (tcp != null &&
        tcp.ok &&
        tls != null &&
        !tls.ok) {
      return NetworkProbeConclusion.sniBlocked;
    }
    if (tcp != null && !tcp.ok) {
      // IP blackholing is only concluded when some DNS source produced a
      // candidate; with none, the result is inconclusive (nothing to test).
      return hadCandidate
          ? NetworkProbeConclusion.ipBlackholed
          : NetworkProbeConclusion.inconclusive;
    }
    if (tls != null && !tls.ok) {
      return NetworkProbeConclusion.inconclusive;
    }
    if (http != null && !http.ok) {
      return NetworkProbeConclusion.appLayer;
    }
    if (tls != null && tls.ok && http != null && http.ok) {
      return NetworkProbeConclusion.allReachable;
    }
    return NetworkProbeConclusion.inconclusive;
  }

  static Future<_ProbeStep> _step(
    String name,
    Future<Object> Function() body,
  ) async {
    try {
      final value = await body();
      final addresses = value is _ProbeValue ? value.addresses : null;
      final detail = value is _ProbeValue ? value.detail : '$value';
      return _ProbeStep(
        NetworkProbeStep(name: name, ok: true, detail: detail),
        dnsAddresses: addresses,
      );
    } on Object catch (error) {
      return _ProbeStep(
        NetworkProbeStep(name: name, ok: false, detail: '$error'),
      );
    }
  }

  static List<InternetAddress>? _addressesOf(_ProbeStep step) =>
      step.dnsAddresses;

  static Future<void> _defaultTcpConnect(
    InternetAddress address,
    int port,
  ) async {
    final socket = await Socket.connect(address, port);
    socket.destroy();
  }

  static Future<void> _defaultTlsHandshake(
    InternetAddress address,
    int port,
    String host,
  ) async {
    final socket = await Socket.connect(address, port);
    try {
      final secure = await SecureSocket.secure(socket, host: host);
      secure.destroy();
    } on Object {
      socket.destroy();
      rethrow;
    }
  }

  static Future<HttpProbeResponse> _defaultMinimalRequest(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      return HttpProbeResponse(response.statusCode);
    } finally {
      client.close(force: true);
    }
  }
}

/// Minimal status carrier so the probe logic does not depend on
/// `package:http`.
class HttpProbeResponse {
  const HttpProbeResponse(this.statusCode);

  final int statusCode;
}

class NetworkProbeLayerException implements Exception {
  const NetworkProbeLayerException(this.message);

  final String message;

  @override
  String toString() => 'NetworkProbeLayerException: $message';
}

class _ProbeValue {
  const _ProbeValue(this.detail, {this.addresses});

  final String detail;
  final List<InternetAddress>? addresses;
}

class _ProbeStep {
  const _ProbeStep(this.step, {this.dnsAddresses});

  final NetworkProbeStep step;
  final List<InternetAddress>? dnsAddresses;
}

/// One probe layer outcome.
class NetworkProbeStep {
  const NetworkProbeStep({
    required this.name,
    required this.ok,
    required this.detail,
  });

  /// Layer name: `system-dns`, `doh`, `tcp`, `tls`, `http`.
  final String name;
  final bool ok;
  final String detail;

  String toLine() => '$name: ${ok ? 'ok' : 'FAILED'} — $detail';
}

enum NetworkProbeConclusion {
  /// 系统 DNS 与 DoH 不一致：DNS 污染，Phase 1（DoH 阶梯）足够。
  dnsPolluted,

  /// DoH/系统 DNS 有地址但 TCP 全部失败：IP 黑洞，客户端无解。
  ipBlackholed,

  /// TCP 通、带真实 SNI 的 TLS 握手失败：SNI 被封，Phase 2 的信号。
  sniBlocked,

  /// TLS 通但最小请求失败：应用层问题，与封锁无关。
  appLayer,

  /// 全链路可达。
  allReachable,

  /// 无法得出确定结论（例如 DoH 本身不可用且没有系统地址）。
  inconclusive,
}

class NetworkProbeReport {
  const NetworkProbeReport({
    required this.host,
    required this.purpose,
    required this.steps,
    required this.conclusion,
    required this.firstError,
  });

  final String host;
  final PixivDestinationPurpose purpose;
  final List<NetworkProbeStep> steps;
  final NetworkProbeConclusion conclusion;
  final String? firstError;

  /// Copy-pasteable report (PRD R2: 结果可复制).
  String toCopyableText() {
    final buffer = StringBuffer()
      ..writeln('NetworkProbe $host (${purpose.name})')
      ..writeln('conclusion: ${conclusion.name}');
    for (final step in steps) {
      buffer.writeln(step.toLine());
    }
    if (firstError != null) {
      buffer.writeln('first-error: $firstError');
    }
    return buffer.toString();
  }
}