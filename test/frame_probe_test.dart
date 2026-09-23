import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/debug/frame_probe.dart';
import 'package:pixiv_func/features/settings/pages/frame_probe_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

FrameTiming _frame(int spanMicros) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: spanMicros ~/ 2,
  rasterStart: spanMicros ~/ 2,
  rasterFinish: spanMicros,
  rasterFinishWallTime: spanMicros,
);

void main() {
  tearDown(() {
    // Singleton: leave no recording or frames behind for other tests —
    // stop() detaches the timings callback, debugClearTimings empties the
    // buffer (debugRecordTimings([]) would not).
    FrameProbe.instance.stop();
    FrameProbe.instance.debugClearTimings();
  });

  test('frame probe keeps at most maxFrames and drops the oldest', () {
    final probe = FrameProbe.instance;
    // A 500ms monster lands first; the full cap of normal frames then evicts
    // it FIFO, so the report's worst line reflects only surviving frames.
    probe.debugRecordTimings([_frame(500000)]);
    probe.debugRecordTimings(
      List<FrameTiming>.filled(FrameProbe.maxFrames, _frame(8000)),
    );

    expect(probe.frameCount, FrameProbe.maxFrames);
    expect(probe.isFull, isTrue);
    final report = probe.report();
    expect(report, contains('frames: ${FrameProbe.maxFrames}'));
    expect(report, contains('worst: total 8.0ms'));
    expect(report, isNot(contains('500.0ms')));
  });

  testWidgets('frame probe keeps recording across page exit and re-entry', (
    tester,
  ) async {
    FrameProbe.instance.stop();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const FrameProbePage(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(FrameProbe.instance.recording, isFalse);
    await tester.tap(find.text('开始记录'));
    await tester.pump();
    expect(FrameProbe.instance.recording, isTrue);
    expect(find.textContaining('录制中'), findsOneWidget);

    // Leaving the page must not stop the recording — the probe's purpose is
    // sampling a different screen.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(FrameProbe.instance.recording, isTrue);

    // Re-entering shows the live status bar again; stop produces the report.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('录制中'), findsOneWidget);
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(FrameProbe.instance.recording, isFalse);
    expect(find.textContaining('frames:'), findsOneWidget);
  });
}
