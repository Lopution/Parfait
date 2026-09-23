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
  void dispose() {
    _ticker?.cancel();
    FrameProbe.instance.stop();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      if (_recording) {
        _ticker?.cancel();
        _ticker = null;
        FrameProbe.instance.stop();
        _report = FrameProbe.instance.report();
      } else {
        _report = null;
        FrameProbe.instance.start();
        _ticker = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => setState(() {}),
        );
      }
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
            FilledButton.icon(
              onPressed: _toggle,
              icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
              label: Text(
                _recording
                    ? context.l10n.frameProbeStop
                    : context.l10n.frameProbeStart,
              ),
            ),
            const SizedBox(height: 16),
            if (_recording)
              Text(
                '${FrameProbe.instance.frameCount} frames',
                style: theme.textTheme.bodyMedium,
              ),
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
