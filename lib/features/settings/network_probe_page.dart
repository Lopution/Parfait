import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_policy.dart';
import '../../core/network/compat/network_probe.dart';
import '../../core/network/compat/network_providers.dart';
import '../../core/network/compat/secure_resolver.dart';
import '../../app/theme/func_tokens.dart';
import 'package:pixiv_func/core/network/pixiv_client_identity.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../core/log.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import 'settings_helpers.dart';

/// Same string as the About page (pubspec `version: 0.1.0`).
const _kAppVersion = '0.1.0';

String _probeText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

String _probeStepLine(BuildContext context, NetworkProbeStep step) {
  final nameKey = switch (step.name) {
    'system-dns' => 'networkProbeStepSystemDns',
    'doh' => 'networkProbeStepDoh',
    'tcp' => 'networkProbeStepTcp',
    'tls' => 'networkProbeStepTls',
    'http' => 'networkProbeStepHttp',
    'ech' => 'networkProbeStepEch',
    'no-sni' => 'networkProbeStepNoSni',
    _ => null,
  };
  final statusKey = step.skipped
      ? 'networkProbeStepSkipped'
      : step.ok
      ? 'networkProbeStepOk'
      : 'networkProbeStepFailed';
  final name = nameKey == null ? step.name : _probeText(context, nameKey);
  return '$name: ${_probeText(context, statusKey)} — ${step.detail} '
      '(${step.duration.inMilliseconds}ms)';
}

/// 分层网络探测页（大陆连通性测量仪器）。
///
/// 对 4 个 Pixiv 自有主机逐层跑：系统 DNS → DoH → TCP → TLS(真实 SNI) →
/// 最小请求。结果决定 Phase 2（省 SNI native 传输）是否需要存在，因此
/// 报告必须可复制、逐层可观察。
class NetworkProbePage extends ConsumerStatefulWidget {
  const NetworkProbePage({super.key});

  @override
  ConsumerState<NetworkProbePage> createState() => _NetworkProbePageState();
}

class _NetworkProbePageState extends ConsumerState<NetworkProbePage> {
  /// Recomputed each build/run so a freshly selected image mirror appears
  /// immediately — the active mirror's hosts are allowlisted on the
  /// policy registry, so the probe can measure them directly.
  List<({String host, PixivDestinationPurpose purpose})> get _targets => [
    (
      host: PixivClientIdentity.appApiBase.host,
      purpose: PixivDestinationPurpose.appApi,
    ),
    (
      host: PixivClientIdentity.oauthHost,
      purpose: PixivDestinationPurpose.oauth,
    ),
    for (final imageHost in PixivClientIdentity.downloadHosts)
      (host: imageHost, purpose: PixivDestinationPurpose.image),
    for (final mirrorHost in ref.read(imageMirrorProvider).extraHosts)
      (host: mirrorHost, purpose: PixivDestinationPurpose.image),
  ];

  final Map<String, NetworkProbeReport?> _finished = {};
  final Map<String, Object> _errors = {};
  bool _running = false;

  NetworkAccessPolicy get _policy => ref.read(networkAccessPolicyProvider);

  NetworkProbeEnvironment _probeEnvironment() {
    final dohEnabled = ref.read(dohEnabledProvider);
    return NetworkProbeEnvironment(
      probedAtUtc: DateTime.now().toUtc(),
      appVersion: _kAppVersion,
      operatingSystem: Platform.operatingSystem,
      operatingSystemVersion: Platform.operatingSystemVersion,
      networkMode: _policy.mode.name,
      dohEndpoints: dohEnabled
          ? List<String>.from(ref.read(dohEndpointsProvider))
          : const [],
      echFrontHost: _policy.echFrontHost,
    );
  }

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _finished.clear();
      _errors.clear();
    });
    final environment = _probeEnvironment();
    try {
      await Future.wait([
        for (final target in _targets)
          _runOne(target, environment).catchError((Object error) {
            log('probe ${target.host} failed: $error');
            if (mounted) {
              setState(() => _errors[target.host] = error);
            }
          }),
      ]);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runOne(
    ({String host, PixivDestinationPurpose purpose}) target,
    NetworkProbeEnvironment environment,
  ) async {
    final resolver = _policy.resolver;
    final report = await NetworkProbe.run(
      host: target.host,
      purpose: target.purpose,
      registry: _policy.registry,
      dohResolver: resolver,
      revision: _policy.revision,
      timeoutPerLayer: const Duration(seconds: 8),
      // The probe's minimal HTTP layer must exercise the same Rust/rhttp
      // transport as production. Use an explicit direct route here so this
      // baseline layer does not recursively invoke the policy ladder.
      minimalRequest: (uri) async {
        final route = NetworkRoute.direct(_policy.revision);
        final request = http.Request('GET', uri)..followRedirects = false;
        final response = await _policy
            .clientFor(target.purpose, route, target.host)
            .send(request);
        await response.stream.drain<void>();
        return HttpProbeResponse(response.statusCode);
      },
      echConfigLookup: resolver is EchConfigResolver
          ? () async {
              try {
                return await (resolver as EchConfigResolver).lookupEchConfig(
                  _policy.echFrontHost,
                  revision: _policy.revision,
                );
              } on Object catch (error) {
                log('ech config lookup failed: ${error.runtimeType}');
                // Keep the original error visible in the report: swallowing
                // it as null collapses every failure mode (endpoint down,
                // no SvcParam, parse error) into the same misleading
                // `no ECH config available` line.
                throw NetworkProbeLayerException(
                  'ECH config lookup failed: ${error.runtimeType}',
                );
              }
            }
          : null,
      echRequest: (uri, address, echConfig) async {
        // ECH transport: the only exit that preserves real SNI encryption
        // (outer SNI cloudflare-ech.com, inner SNI app-api.pixiv.net).
        //
        // The config and the connect address BOTH come from the lookup
        // result carried through this callback — never from shared state.
        // An earlier version read them from an instance field written by
        // four concurrently running host probes (a race) and silently fell
        // back to an empty config list when the cast failed, which made this
        // layer report `ok` for a plain-TLS connection that never used ECH
        // at all. A wrong type is now a hard failure.
        if (echConfig is! EchConfigResult) {
          throw NetworkProbeLayerException(
            'ECH config has unexpected type ${echConfig.runtimeType}',
          );
        }
        final configBytes = NetworkProbe.requireEchConfigBytes(echConfig);
        // The connect target MUST be the ECH front's anycast IP (ipv4hint
        // from its HTTPS RR), NOT the target host's answer: mainland answers
        // for the target are polluted and the handshake would go nowhere.
        final frontAddress =
            echConfig.frontAddresses
                .where(isPublicNetworkAddress)
                .firstOrNull ??
            address;
        final route = NetworkRoute.ech(
          _policy.revision,
          frontAddress,
          configBytes,
        );
        final client = _policy.clientFor(target.purpose, route, target.host);
        try {
          final response = await client
              .get(uri)
              .timeout(const Duration(seconds: 8));
          return HttpProbeResponse(response.statusCode);
        } on Object catch (error) {
          // Surface the transport error verbatim plus the config size so a
          // probe run pinpoints ECH config/parse/negotiation failures.
          throw NetworkProbeLayerException(
            'ECH request failed (config ${echConfig.echConfig.length}B, '
            'front ${frontAddress.address}): $error',
          );
        }
      },
      noSniHandshake: (address, _) async {
        // Empty-SNI handshake requires a rustls client with sni=false;
        // implemented via the policy's rhttp transport (a GET to the probe
        // path with the noSni tier). This is the probe page asking "does
        // empty SNI work on this host".
        final route = NetworkRoute.noSni(_policy.revision, address);
        final client = _policy.clientFor(target.purpose, route, target.host);
        try {
          await client
              .get(Uri.parse('https://${target.host}${NetworkProbe.probePath}'))
              .timeout(const Duration(seconds: 8));
        } finally {
          // Pooled client: do not close here (owned by the policy).
        }
      },
      httpNoSniRequest: (uri, address) async {
        final route = NetworkRoute.noSni(_policy.revision, address);
        final client = _policy.clientFor(target.purpose, route, target.host);
        try {
          final response = await client
              .get(uri)
              .timeout(const Duration(seconds: 8));
          return HttpProbeResponse(response.statusCode);
        } on Object catch (error) {
          throw NetworkProbeLayerException('no-SNI request failed: $error');
        }
      },
    );
    if (mounted) {
      setState(() {
        _errors.remove(target.host);
        _finished[target.host] = report.copyWith(environment: environment);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.networkProbeTitle)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              context.l10n.networkProbeHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            // Reports live only in page state — say so instead of letting the
            // user expect history (spec: probe results are not persisted).
            Text(
              context.l10n.networkProbeNotPersisted,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _running ? null : _runAll,
              icon: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(
                _running
                    ? context.l10n.networkProbeRunning
                    : context.l10n.networkProbeRun,
              ),
            ),
            const SizedBox(height: 16),
            if (_finished.isNotEmpty || _errors.isNotEmpty)
              NetworkProbeOverview(reports: _finished, errors: _errors),
            for (final target in _targets)
              NetworkProbeHostPanel(
                host: target.host,
                report: _finished[target.host],
                error: _errors[target.host],
                running: _running,
              ),
          ],
        ),
      ),
    );
  }
}

/// Summary-first overview (design §9): conclusion counts, the worst host and
/// one actionable suggestion sit above the per-host detail cards.
class NetworkProbeOverview extends StatelessWidget {
  const NetworkProbeOverview({
    super.key,
    required this.reports,
    required this.errors,
  });

  final Map<String, NetworkProbeReport?> reports;
  final Map<String, Object> errors;

  /// Worse-first ordering for the counts line and the "worst" pick.
  static int _severity(NetworkProbeConclusion c) => switch (c) {
    NetworkProbeConclusion.ipBlackholed => 7,
    NetworkProbeConclusion.sniBlocked => 6,
    NetworkProbeConclusion.dnsPolluted => 5,
    NetworkProbeConclusion.appLayer => 4,
    NetworkProbeConclusion.inconclusive => 3,
    NetworkProbeConclusion.noSniAvailable => 2,
    NetworkProbeConclusion.echAvailable => 1,
    NetworkProbeConclusion.allReachable => 0,
  };

  static String _adviceKey(NetworkProbeConclusion c) => switch (c) {
    NetworkProbeConclusion.ipBlackholed => 'networkProbeAdviceIpBlackholed',
    NetworkProbeConclusion.sniBlocked => 'networkProbeAdviceSniBlocked',
    NetworkProbeConclusion.dnsPolluted => 'networkProbeAdviceDnsPolluted',
    NetworkProbeConclusion.appLayer => 'networkProbeAdviceAppLayer',
    NetworkProbeConclusion.inconclusive => 'networkProbeAdviceInconclusive',
    NetworkProbeConclusion.noSniAvailable => 'networkProbeAdviceNoSniAvailable',
    NetworkProbeConclusion.echAvailable => 'networkProbeAdviceEchAvailable',
    NetworkProbeConclusion.allReachable => 'networkProbeAdviceAllReachable',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finished = reports.values.whereType<NetworkProbeReport>().toList();
    final counts = <NetworkProbeConclusion, int>{};
    for (final report in finished) {
      counts[report.conclusion] = (counts[report.conclusion] ?? 0) + 1;
    }
    final ranked = counts.keys.toList()
      ..sort((a, b) => _severity(b).compareTo(_severity(a)));
    final worst = finished.isEmpty
        ? null
        : finished.reduce(
            (a, b) =>
                _severity(a.conclusion) >= _severity(b.conclusion) ? a : b,
          );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.networkProbeOverview,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final conclusion in ranked)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ConclusionBadge(conclusion: conclusion),
                      Text(
                        ' ×${counts[conclusion]}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                if (errors.isNotEmpty)
                  Text(
                    '${context.l10n.networkProbeHostFailed} '
                    '×${errors.length}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
            if (worst != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '${context.l10n.networkProbeWorst}: ${worst.host}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ConclusionBadge(conclusion: worst.conclusion),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _probeText(context, _adviceKey(worst.conclusion)),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class NetworkProbeHostPanel extends StatelessWidget {
  const NetworkProbeHostPanel({
    super.key,
    required this.host,
    required this.report,
    required this.error,
    required this.running,
  });

  final String host;
  final NetworkProbeReport? report;
  final Object? error;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = report;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    host,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (body != null) _ConclusionBadge(conclusion: body.conclusion),
                if (body == null && running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (error != null)
              Text(
                '${context.l10n.networkProbeHostFailed}: $error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (body == null)
              Text(
                running
                    ? context.l10n.networkProbeRunning
                    : context.l10n.networkProbeNotRun,
                style: theme.textTheme.bodySmall,
              )
            else ...[
              if (body.firstError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    body.firstError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ExpansionTile(
                title: Text(context.l10n.networkProbeDetails),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                children: [
                  if (body.dnsDisagrees)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        context.l10n.networkProbeDnsDiff,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: FuncTokens.networkProbeDnsWarning,
                        ),
                      ),
                    ),
                  for (final step in body.steps)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _probeStepLine(context, step),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: step.ok ? null : theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: body.toCopyableText()),
                        );
                        showAppSnackBar(
                          context,
                          context.l10n.networkProbeCopied,
                        );
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: Text(context.l10n.copy),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConclusionBadge extends StatelessWidget {
  const _ConclusionBadge({required this.conclusion});

  final NetworkProbeConclusion conclusion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (key, color) = switch (conclusion) {
      NetworkProbeConclusion.allReachable => (
        'networkProbeConclusionAllReachable',
        FuncTokens.networkProbeSuccess,
      ),
      NetworkProbeConclusion.dnsPolluted => (
        'networkProbeConclusionDnsPolluted',
        FuncTokens.networkProbeWarning,
      ),
      NetworkProbeConclusion.sniBlocked => (
        'networkProbeConclusionSniBlocked',
        FuncTokens.networkProbeError,
      ),
      NetworkProbeConclusion.echAvailable => (
        'networkProbeConclusionEchAvailable',
        FuncTokens.networkProbeEch,
      ),
      NetworkProbeConclusion.noSniAvailable => (
        'networkProbeConclusionNoSniAvailable',
        FuncTokens.networkProbeNoSni,
      ),
      NetworkProbeConclusion.ipBlackholed => (
        'networkProbeConclusionIpBlackholed',
        FuncTokens.networkProbeError,
      ),
      NetworkProbeConclusion.appLayer => (
        'networkProbeConclusionAppLayer',
        FuncTokens.networkProbeWarning,
      ),
      NetworkProbeConclusion.inconclusive => (
        'networkProbeConclusionInconclusive',
        FuncTokens.networkProbeNeutral,
      ),
    };
    final resolvedColor = color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: resolvedColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _probeText(context, key),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
