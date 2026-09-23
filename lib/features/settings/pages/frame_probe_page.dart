import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../app/widgets/app_snack_bar.dart';
import '../../../core/debug/frame_probe.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Dev-only frame probe page: record timings while scrolling a feed, then
/// copy the build/raster percentile report for offline analysis. Only
/// reachable in debug/profile builds — the settings tile is release-gated.
class FrameProbePage extends StatefulWidget {
  const FrameProbePage({super.key});

  @override
  State<FrameProbePage> createState() => _FrameProbePageState();
}

class _FrameProbePageState extends State<FrameProbePage> {
  Timer? _ticker;
  String? _report;

  bool get _recording => FrameProbe.instance.recording;

  @override
  void initState() {
    super.initState();
    // Re-entering while a recording is still live: resume the ticker so the
    // status bar keeps refreshing — the probe itself never stopped.
    if (_recording) _startTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // Deliberately no FrameProbe.stop(): the recording's whole point is to
    // sample a different page, so leaving this page must not end it.
    super.dispose();
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  void _start() {
    setState(() {
      _report = null;
      FrameProbe.instance.start();
      _startTicker();
    });
  }

  void _stop() {
    setState(() {
      _ticker?.cancel();
      _ticker = null;
      FrameProbe.instance.stop();
      _report = FrameProbe.instance.report();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.frameProbeTitle)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(context.l10n.frameProbeHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_recording)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.fiber_manual_record,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
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
            const SizedBox(height: 16),
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
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _report!));
                    showAppSnackBar(context, context.l10n.networkProbeCopied);
                  },
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
