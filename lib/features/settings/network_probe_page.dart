import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/replica_strings.dart';
import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_policy.dart';
import '../../core/network/compat/network_probe.dart';
import '../../core/network/compat/network_providers.dart';
import '../../core/network/compat/secure_resolver.dart';

String _probeText(BuildContext context, String key) {
  return ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );
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
  final List<({String host, PixivDestinationPurpose purpose})> _targets = [
    (host: 'app-api.pixiv.net', purpose: PixivDestinationPurpose.appApi),
    (host: 'oauth.secure.pixiv.net', purpose: PixivDestinationPurpose.oauth),
    (host: 'i.pximg.net', purpose: PixivDestinationPurpose.image),
    (host: 's.pximg.net', purpose: PixivDestinationPurpose.image),
  ];

  final Map<String, NetworkProbeReport?> _finished = {};
  bool _running = false;

  NetworkAccessPolicy get _policy =>
      ref.read(networkAccessPolicyProvider);

  Future<void> _runAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _finished.clear();
    });
    try {
      await Future.wait([
        for (final target in _targets)
          _runOne(target).catchError((Object error) {
            debugPrint('probe ${target.host} failed: $error');
          }),
      ]);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runOne(
    ({String host, PixivDestinationPurpose purpose}) target,
  ) async {
    final resolver = _policy.resolver;
    final report = await NetworkProbe.run(
      host: target.host,
      purpose: target.purpose,
      registry: _policy.registry,
      dohResolver: resolver,
      revision: _policy.revision,
      timeoutPerLayer: const Duration(seconds: 8),
      echConfigLookup: resolver is DohResolver
          ? () async {
              try {
                return await resolver.lookupEchConfig(
                  _policy.echFrontHost,
                  revision: _policy.revision,
                );
              } on Object catch (error) {
                debugPrint('ech config lookup failed: $error');
                // Keep the original error visible in the report: swallowing
                // it as null collapses every failure mode (endpoint down,
                // no SvcParam, parse error) into the same misleading
                // `no ECH config available` line.
                throw NetworkProbeLayerException(
                  'ECH config lookup failed: $error',
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
        final frontAddress = echConfig.frontAddresses.isNotEmpty
            ? echConfig.frontAddresses.first
            : address;
        final route = NetworkRoute.ech(
          _policy.revision,
          frontAddress,
          configBytes,
        );
        final client = _policy.clientFor(
          target.purpose,
          route,
          target.host,
        );
        try {
          final response =
              await client.get(uri).timeout(const Duration(seconds: 8));
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
      noSniHandshake: (_address, _port) async {
        // Empty-SNI handshake requires a rustls client with sni=false;
        // implemented via the policy's rhttp transport (a GET to the probe
        // path with the noSni tier). This is the probe page asking "does
        // empty SNI work on this host".
        final route = NetworkRoute.noSni(_policy.revision, _address);
        final client = _policy.clientFor(
          target.purpose,
          route,
          target.host,
        );
        try {
          await client
              .get(Uri.parse('https://${target.host}${NetworkProbe.probePath}'))
              .timeout(const Duration(seconds: 8));
        } finally {
          // Pooled client: do not close here (owned by the policy).
        }
      },
      httpNoSniRequest: (uri, _address) async {
        final route = NetworkRoute.noSni(_policy.revision, _address);
        final client = _policy.clientFor(
          target.purpose,
          route,
          target.host,
        );
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
      setState(() => _finished[target.host] = report);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_probeText(context, 'networkProbeTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _probeText(context, 'networkProbeHint'),
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
                  ? _probeText(context, 'networkProbeRunning')
                  : _probeText(context, 'networkProbeRun'),
            ),
          ),
          const SizedBox(height: 16),
          for (final target in _targets)
            _HostProbeCard(
              host: target.host,
              report: _finished[target.host],
              running: _running,
            ),
        ],
      ),
    );
  }
}

class _HostProbeCard extends StatelessWidget {
  const _HostProbeCard({
    required this.host,
    required this.report,
    required this.running,
  });

  final String host;
  final NetworkProbeReport? report;
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
            if (body == null)
              Text(
                running
                    ? _probeText(context, 'networkProbeRunning')
                    : _probeText(context, 'networkProbeNotRun'),
                style: theme.textTheme.bodySmall,
              )
            else ...[
              for (final step in body.steps)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    step.toLine(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: step.ok
                          ? null
                          : theme.colorScheme.error,
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          _probeText(context, 'networkProbeCopied'),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(_probeText(context, 'copy')),
                ),
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
    final (label, color) = switch (conclusion) {
      NetworkProbeConclusion.allReachable => (
        'OK',
        Colors.green.shade700,
      ),
      NetworkProbeConclusion.dnsPolluted => (
        'DNS 污染',
        Colors.orange.shade700,
      ),
      NetworkProbeConclusion.sniBlocked => (
        'SNI 被封',
        Colors.red.shade700,
      ),
      NetworkProbeConclusion.echAvailable => (
        '应选 ECH',
        Colors.teal.shade700,
      ),
      NetworkProbeConclusion.noSniAvailable => (
        '应选空 SNI',
        Colors.indigo.shade700,
      ),
      NetworkProbeConclusion.ipBlackholed => (
        'IP 黑洞',
        Colors.red.shade700,
      ),
      NetworkProbeConclusion.appLayer => (
        '应用层',
        Colors.orange.shade700,
      ),
      NetworkProbeConclusion.inconclusive => (
        '不确定',
        Colors.grey.shade600,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}