import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/debug/frame_probe.dart';

FrameTiming _frame(int spanMicros) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: spanMicros ~/ 2,
  rasterStart: spanMicros ~/ 2,
  rasterFinish: spanMicros,
  rasterFinishWallTime: spanMicros,
);

extension on FrameTiming {}

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
    expect(report, contains('s 8.0 = wait 0.0 + ui 4.0'));
    expect(report, isNot(contains('500.0')));
  });

  testWidgets('vsync gaps bucket by panel period, split by finger state', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final probe = FrameProbe.instance..start();
    void frame(int number) => probe
      ..beginUiFrame()
      ..endUiFrame(number);

    frame(1);
    final gesture = await tester.startGesture(const Offset(10, 10));
    frame(2);
    await gesture.up();
    frame(3);
    frame(4);
    probe.stop();
    // 120Hz period 8.333ms: frame 2 lands on time under the finger, frame 3
    // skips a vsync after release, frame 4 comes from a faster panel mode.
    FrameTiming at(int vsync, int number) => FrameTiming(
      vsyncStart: vsync,
      buildStart: vsync,
      buildFinish: vsync + 1000,
      rasterStart: vsync + 1000,
      rasterFinish: vsync + 2000,
      rasterFinishWallTime: vsync + 2000,
      frameNumber: number,
    );
    probe.debugRecordTimings([
      at(0, 1),
      at(8333, 2),
      at(25000, 3),
      at(31944, 4),
    ]);

    final report = probe.report();
    expect(
      report,
      contains(
        '  all (3, min 6.9) <7.5: 1  7.5-10.0: 1  10.0-13.3: 0  '
        '13.3-20.8: 1  >20.8: 0',
      ),
    );
    expect(
      report,
      contains(
        '  touch (1, min 8.3) <7.5: 0  7.5-10.0: 1  10.0-13.3: 0  '
        '13.3-20.8: 0  >20.8: 0',
      ),
    );
    expect(
      report,
      contains(
        '  released (2, min 6.9) <7.5: 1  7.5-10.0: 0  10.0-13.3: 0  '
        '13.3-20.8: 1  >20.8: 0',
      ),
    );
    expect(report, contains('| touch | layers: '));
  }, semanticsEnabled: false);

  testWidgets('slowest frames split by phase and name the work before them', (
    tester,
  ) async {
    final probe = FrameProbe.instance..start();
    // Binding hook order for one frame, with a decode between frames and a
    // feed commit inside the frame.
    probe.measure('json 180KB', () {});
    probe
      ..beginUiFrame()
      ..timePhase(UiPhase.animate, () {})
      ..timePhase(UiPhase.frame, () {
        probe.timePhase(UiPhase.draw, () {
          probe.timePhase(UiPhase.layout, () {});
          probe.measure('feed commit 30', () {});
          probe.mark('img 540x810');
        });
      })
      ..endUiFrame(7)
      ..stop();
    probe.debugRecordTimings([
      FrameTiming(
        vsyncStart: 0,
        buildStart: 30000,
        buildFinish: 31000,
        rasterStart: 32000,
        rasterFinish: 33000,
        rasterFinishWallTime: 33000,
        frameNumber: 7,
      ),
      // No hook record for this frame: totals only, no phase bracket.
      FrameTiming(
        vsyncStart: 40000,
        buildStart: 40000,
        buildFinish: 41000,
        rasterStart: 41000,
        rasterFinish: 42000,
        rasterFinishWallTime: 42000,
        frameNumber: 8,
      ),
    ]);

    final report = probe.report();
    expect(report, contains('late start (wait > budget): 1'));
    expect(report, contains('semantics: off'));
    expect(
      report,
      matches(
        RegExp(
          r'  \+0\.00s 33\.0 = wait 30\.0 \+ ui 1\.0 '
          r'\[anim [\d.]+ build [\d.]+ layout [\d.]+ paint 0\.0 sem 0\.0 '
          r'post [\d.]+\] \+ queue 1\.0 \+ raster 1\.0 '
          r'\| before: json 180KB [\d.]+ '
          r'\| during: feed commit 30 [\d.]+, img 540x810 '
          r'\| layers: \d+ total, \d+ pictures',
        ),
      ),
    );
    expect(
      report,
      contains('  +0.04s 2.0 = wait 0.0 + ui 1.0 + queue 0.0 + raster 1.0\n'),
    );
  }, semanticsEnabled: false);
}
