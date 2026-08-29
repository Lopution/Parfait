import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/replica_strings.dart';
import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_policy.dart';
import '../../core/network/compat/network_probe.dart';
import '../../core/network/compat/network_providers.dart';

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
    final report = await NetworkProbe.run(
      host: target.host,
      purpose: target.purpose,
      registry: _policy.registry,
      dohResolver: _policy.resolver,
      revision: _policy.revision,
      timeoutPerLayer: const Duration(seconds: 8),
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