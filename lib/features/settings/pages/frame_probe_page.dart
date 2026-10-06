import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_top_bar.dart';
import '../../../core/debug/frame_probe.dart';
import '../../../core/image/image_worker_providers.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/clipboard.dart';

/// Dev-only frame probe page: record timings while scrolling a feed, then
/// copy the build/raster percentile report for offline analysis. Only
/// reachable in debug/profile builds — the settings tile is release-gated.
/// The image worker's state rides along: queue depth and disk usage explain
/// what the frames were waiting on.
class FrameProbePage extends ConsumerStatefulWidget {
  const FrameProbePage({super.key});

  @override
  ConsumerState<FrameProbePage> createState() => _FrameProbePageState();
}

class _FrameProbePageState extends ConsumerState<FrameProbePage> {
  Timer? _ticker;
  String? _report;
  String? _worker;

  bool get _recording => FrameProbe.instance.recording;

  @override
  void initState() {
    super.initState();
    // Re-entering while a recording is still live: resume the ticker so the
    // status bar keeps refreshing — the probe itself never stopped.
    if (_recording) _startTicker();
    unawaited(_refreshWorker());
  }

  Future<String> _describeWorker() async =>
      (await ref.read(imageWorkerProvider).snapshot()).describe();

  Future<void> _refreshWorker() async {
    final worker = await _describeWorker();
    if (mounted) setState(() => _worker = worker);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // Deliberately no FrameProbe.stop(): the recording's whole point is to
    // sample a different page, so leaving this page must not end it.
    super.dispose();
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      setState(() {});
      unawaited(_refreshWorker());
    });
  }

  void _start() {
    setState(() {
      _report = null;
      FrameProbe.instance.start();
      _startTicker();
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    _ticker = null;
    FrameProbe.instance.stop();
    final report = FrameProbe.instance.report();
    final display = await _describeDisplay();
    final worker = await _describeWorker();
    if (!mounted) return;
    setState(() {
      _worker = worker;
      _report = '$report$display$worker';
    });
  }

  /// The panel modes Android lists: MainActivity's surface vote asks for
  /// the highest rate here, so a list topping out above the reported
  /// refresh rate means the vote can pull the panel into a faster mode.
  static Future<String> _describeDisplay() async {
    if (!Platform.isAndroid) return '';
    try {
      final supported = await FlutterDisplayMode.supported;
      final active = await FlutterDisplayMode.active;
      final modes = {
        for (final mode in supported)
          // Skips the plugin's synthetic `auto` entry (all zeros).
          if (mode.refreshRate > 0)
            '${mode.width}x${mode.height}@${mode.refreshRate.toStringAsFixed(1)}',
      };
      return 'display modes: ${modes.join(', ')}\n'
          'active mode: ${active.width}x${active.height}'
          '@${active.refreshRate.toStringAsFixed(1)}\n';
    } on PlatformException catch (error) {
      return 'display modes: unavailable (${error.code})\n';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppTopBar(title: Text(context.l10n.frameProbeTitle)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.all(FuncSpacing.lg),
          children: [
            Text(context.l10n.frameProbeHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: FuncSpacing.md),
            if (_recording)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FuncSpacing.md,
                    vertical: FuncSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.fiber_manual_record,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: FuncSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${context.l10n.frameProbeRecording} · '
                              '${FrameProbe.instance.frameCount} frames',
                              style: theme.textTheme.bodyMedium,
                            ),
                            if (FrameProbe.instance.isFull)
                              Text(
                                context.l10n.frameProbeCapHint,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _stop,
                        child: Text(context.l10n.frameProbeStop),
                      ),
                    ],
                  ),
                ),
              )
            else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.fiber_manual_record),
                label: Text(context.l10n.frameProbeStart),
              ),
            if (_worker case final worker?) ...[
              const SizedBox(height: FuncSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      worker.trimRight(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _refreshWorker,
                    tooltip: context.l10n.refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ],
            const SizedBox(height: FuncSpacing.lg),
            if (_report != null) ...[
              SelectableText(
                _report!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => copyToClipboard(
                    context,
                    _report!,
                    message: context.l10n.networkProbeCopied,
                  ),
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(context.l10n.copy),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
