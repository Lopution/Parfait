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

FrameTiming _timed({
  required int vsync,
  required int build,
  required int raster,
}) => FrameTiming(
  vsyncStart: vsync,
  buildStart: vsync,
  buildFinish: vsync + build,
  rasterStart: vsync + build,
  rasterFinish: vsync + build + raster,
  rasterFinishWallTime: vsync + build + raster,
);

void main() {
  test('PIXIV_FRAME_PROBE stays unset in a default build', () {
    // The release exception is opt-in: a build without the dart-define —
    // including this test run — must keep the entry hidden. This guards
    // the const from drifting to an enabled default.
    expect(kPixivFrameProbe, isFalse);
  });

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

  testWidgets('frame budget and intervals follow the panel refresh rate', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final probe = FrameProbe.instance;
    probe.debugRecordTimings([
      _timed(vsync: 0, build: 4000, raster: 5000),
      // 9ms build: fine at 60Hz, a missed vsync at 120Hz.
      _timed(vsync: 8333, build: 9000, raster: 3000),
      _timed(vsync: 16666, build: 3000, raster: 3000),
      // One vsync skipped, and a raster stage over two budgets.
      _timed(vsync: 33333, build: 3000, raster: 18000),
      // Nearly a second later: idle, not a stall.
      _timed(vsync: 1000000, build: 2000, raster: 2000),
    ]);

    final report = probe.report();
    expect(report, contains('display: 120Hz, frame budget 8.3ms'));
    expect(report, contains('over budget: 2 (40.0%)  >2x budget: 1'));
    expect(report, contains('interval: p50 8.333ms'));
    expect(report, contains('max 16.667ms'));
    expect(report, isNot(contains('966.667ms')));

    tester.view.display.refreshRate = 0;
    expect(
      probe.report(),
      contains('display: 60Hz (not reported, assumed), frame budget 16.7ms'),
    );
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
