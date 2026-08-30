import 'dart:async';
import 'dart:io';

import 'network_contracts.dart';
import 'secure_resolver.dart';

/// Layered connectivity probe for one Pixiv destination host.
///
/// The probe is the *measuring instrument* that decides which policy tier
/// (direct / ECH / dohRealSni / noSni) works on the current network. Each
/// layer is falsifiable on its own, and the combination maps deterministically
/// to a conclusion:
///
/// | observation | conclusion |
/// |---|---|
/// | system DNS != DoH addresses | DNS pollution — DoH tier suffices |
/// | DoH has answers but TCP fails | IP blackholing — no client-side fix |
/// | TCP ok but TLS handshake (real SNI) fails | SNI blocked — ECH/noSni tier |
/// | ECH config available AND ECH handshake ok | `ech` tier is the answer |
/// | TCP ok, real-SNI fails, ECH fails, empty-SNI handshake ok | `noSni` tier |
/// | HTTP 421 with empty SNI | link ok but Host/cert mismatch — tier unusable |
/// | TLS ok but minimal request fails | app-layer issue, unrelated to blocking |
///
/// All I/O is injected ([socketFactory], [systemLookup], [resolver], the
/// transport for the minimal request, ECH lookup/handshake), so the whole
/// matrix is unit-testable offline; the real implementation defaults to the
/// platform primitives.
abstract final class NetworkProbe {
  /// Namespace constant for the probe HTTP request path; the probe never
  /// sends credentials or cookies.
  static const probePath = '/v1/illust/prime';

  /// Runs every layer for [host] and returns a step-by-step report.
  ///
  /// [purpose] selects the registry scope so the probe cannot be pointed at
  /// arbitrary hosts; [timeoutPerLayer] bounds each network step. New layers
  /// (ECH, empty-SNI, 421) are injected so the entire matrix is offline
  /// testable. When the injected functions are null, the layer is reported
  /// as `skipped` (the probe page passes real implementations through the
  /// policy's rhttp transport).
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
    Future<Object?> Function()? echConfigLookup,
    Future<HttpProbeResponse> Function(
      Uri uri,
      InternetAddress address,
      Object? echConfig,
    )? echRequest,
    Future<void> Function(InternetAddress address, int port)?
    noSniHandshake,
    Future<HttpProbeResponse> Function(
      Uri uri,
      InternetAddress address,
    )? httpNoSniRequest,
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
      echConfigLookup: echConfigLookup,
      echRequest: echRequest,
      noSniHandshake: noSniHandshake,
      httpNoSniRequest: httpNoSniRequest,
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
    required Future<Object?> Function()? echConfigLookup,
    required Future<HttpProbeResponse> Function(
      Uri uri,
      InternetAddress address,
      Object? echConfig,
    )? echRequest,
    required Future<void> Function(InternetAddress address, int port)?
    noSniHandshake,
    required Future<HttpProbeResponse> Function(
      Uri uri,
      InternetAddress address,
    )? httpNoSniRequest,
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

    // Layer 6: ECH config availability + ECH handshake. Injected: the probe
    // page binds these to the policy's rhttp transport (only Rust can drive
    // ECH), tests inject fakes. When no ECH prober is configured the layer
    // is omitted entirely (absence is not evidence).
    if (echConfigLookup != null) {
      final ech = await _step('ech', () async {
        final Object? configResult;
        try {
          configResult = await echConfigLookup().timeout(timeoutPerLayer);
        } on Object catch (error) {
          throw NetworkProbeLayerException('ECH config lookup failed: $error');
        }
        if (configResult == null) {
          throw const NetworkProbeLayerException('no ECH config available');
        }
        if (configResult is! EchConfigResult) {
          // The callback contract is the FULL lookup result: the probe page
          // re-extracts both the config bytes and the front addresses, so
          // handing it a pre-split byte list would break that contract and
          // (worse) a previous version silently substituted an empty list,
          // letting the layer report `ok` for a plain-TLS connection that
          // never used ECH. An unexpected type is a hard failure.
          throw NetworkProbeLayerException(
            'ECH config lookup returned unexpected type '
            '${configResult.runtimeType}',
          );
        }
        final configBytes = requireEchConfigBytes(configResult);
        // The ECH handshake connects the FRONT host's anycast IP (from the
        // HTTPS RR ipv4hint), not the target host's answer — that answer is
        // polluted on mainland networks and its TCP pre-check would time
        // out even though ECH works. Use the front address when the lookup
        // carried one.
        final Object? frontAddress = configResult.frontAddresses.isNotEmpty
            ? configResult.frontAddresses.first
            : null;
        final tcpPeer =
            frontAddress is InternetAddress ? frontAddress : tcpTarget;
        if (tcpPeer == null) {
          throw const NetworkProbeLayerException('no candidate address');
        }
        await tcpConnect(tcpPeer, 443).timeout(timeoutPerLayer);
        final transport = echRequest;
        if (transport == null) {
          // A config was measured but no ECH transport is wired: reporting
          // `ok` through the plain-TLS minimal request was the exact false
          // positive that made this layer untrustworthy (a plain-TLS
          // request is not an ECH measurement). Without a transport the
          // layer cannot measure ECH and must say so.
          throw const NetworkProbeLayerException(
            'no ECH transport prober configured',
          );
        }
        final uri = Uri.parse('https://$host$probePath');
        final response = await transport(uri, tcpPeer, configResult)
            .timeout(timeoutPerLayer);
        // [configBytes] is validated above (type + non-empty) so the layer
        // never measures an empty or malformed config.
        return 'ECH config available (${configBytes.length}B); '
            'probe request HTTP ${response.statusCode}';
      });
      steps.add(ech.step);
      if (!ech.step.ok) firstError ??= ech.step.detail;
    }

    // Layer 7: empty-SNI handshake (origin hosts). Only meaningful when the
    // real-SNI handshake failed; injected; omitted when not configured.
    if (noSniHandshake != null || httpNoSniRequest != null) {
      final noSni = await _step('no-sni', () async {
        if (tcpTarget == null) {
          throw const NetworkProbeLayerException('no candidate address');
        }
        final uri = Uri.parse('https://$host$probePath');
        if (httpNoSniRequest != null) {
          final response =
              await httpNoSniRequest(uri, tcpTarget).timeout(timeoutPerLayer);
          if (response.statusCode == 421) {
            throw const NetworkProbeLayerException(
              'HTTP 421: link ok but certificate/Host mismatch',
            );
          }
          return 'empty-SNI request HTTP ${response.statusCode}';
        }
        await noSniHandshake!(tcpTarget, 443).timeout(timeoutPerLayer);
        return 'empty-SNI handshake ok';
      });
      steps.add(noSni.step);
      if (!noSni.step.ok) firstError ??= noSni.step.detail;
    }

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
    final ech = byName('ech');
    final noSni = byName('no-sni');

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
    if (tcp != null && !tcp.ok) {
      // IP blackholing is only concluded when some DNS source produced a
      // candidate; with none, the result is inconclusive (nothing to test).
      return hadCandidate
          ? NetworkProbeConclusion.ipBlackholed
          : NetworkProbeConclusion.inconclusive;
    }
    if (tls != null && !tls.ok) {
      // Real-SNI handshake failed: the wall is blocking the SNI. Prefer ECH
      // when it measured ok; origin hosts fall back to empty-SNI.
      if (ech != null && ech.ok) {
        return NetworkProbeConclusion.echAvailable;
      }
      if (noSni != null && noSni.ok) {
        return NetworkProbeConclusion.noSniAvailable;
      }
      return NetworkProbeConclusion.sniBlocked;
    }
    if (tls != null && tls.ok && http != null && http.ok) {
      return NetworkProbeConclusion.allReachable;
    }
    if (tls != null && !tls.ok) {
      return NetworkProbeConclusion.inconclusive;
    }
    if (http != null && !http.ok) {
      return NetworkProbeConclusion.appLayer;
    }
    return NetworkProbeConclusion.inconclusive;
  }

  /// Extracts the ECH config bytes an ECH probe request must use.
  ///
  /// Guards the `ech` layer against reporting a false `ok`. An earlier version
  /// of the probe page narrowed the lookup result with `is List<int>` — which
  /// an [EchConfigResult] never satisfies — and silently substituted an empty
  /// config list. The layer then measured a plain-TLS connection to the ECH
  /// front and reported ECH as working while the real ECH path was failing,
  /// which is exactly the kind of silent fallback that makes a probe useless.
  ///
  /// Both an unexpected type and an empty config are hard failures: the layer
  /// must report why it could not measure ECH, never quietly measure
  /// something else.
  static List<int> requireEchConfigBytes(Object? lookupResult) {
    if (lookupResult is! EchConfigResult) {
      throw NetworkProbeLayerException(
        'ECH config has unexpected type ${lookupResult.runtimeType}',
      );
    }
    if (lookupResult.echConfig.isEmpty) {
      throw const NetworkProbeLayerException('ECH config list is empty');
    }
    return lookupResult.echConfig;
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
    this.skipped = false,
  });

  /// Layer name: `system-dns`, `doh`, `tcp`, `tls`, `http`, `ech`,
  /// `no-sni`.
  final String name;
  final bool ok;
  final String detail;

  /// True when the layer was not run (no prober configured). Skipping is
  /// not evidence either way.
  final bool skipped;
  String toLine() => '$name: ${ok ? 'ok' : 'FAILED'} — $detail';
}

enum NetworkProbeConclusion {
  /// 系统 DNS 与 DoH 不一致：DNS 污染，DoH 阶梯足够。
  dnsPolluted,

  /// DoH/系统 DNS 有地址但 TCP 全部失败：IP 黑洞，客户端无解。
  ipBlackholed,

  /// TCP 通、带真实 SNI 的 TLS 握手失败：SNI 被封，ECH 档应为首选。
  sniBlocked,

  /// ECH config 可用且 ECH 握手成功：当前网络下应选 ECH 档。
  echAvailable,

  /// 真实 SNI 失败但空 SNI 可用（源站）：应选 noSni 档。
  noSniAvailable,

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