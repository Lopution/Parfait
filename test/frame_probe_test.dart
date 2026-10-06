import 'dart:ui' show FramePhase;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/debug/frame_probe.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/features/settings/pages/frame_probe_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/image_network.dart';

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

extension on FrameTiming {
  FrameTiming copyWithNumber(int number) => FrameTiming(
    vsyncStart: timestampInMicroseconds(FramePhase.vsyncStart),
    buildStart: timestampInMicroseconds(FramePhase.buildStart),
    buildFinish: timestampInMicroseconds(FramePhase.buildFinish),
    rasterStart: timestampInMicroseconds(FramePhase.rasterStart),
    rasterFinish: timestampInMicroseconds(FramePhase.rasterFinish),
    rasterFinishWallTime: timestampInMicroseconds(
      FramePhase.rasterFinishWallTime,
    ),
    frameNumber: number,
  );
}

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

  testWidgets('slow frames name their live scenes and the tags rank them', (
    tester,
  ) async {
    final probe = FrameProbe.instance..start();
    probe
      ..enter('snapshot')
      ..beginUiFrame()
      ..endUiFrame(1)
      ..exit('snapshot')
      ..beginUiFrame()
      ..endUiFrame(2)
      ..beginUiFrame()
      ..endUiFrame(3)
      ..stop();
    probe.debugRecordTimings([
      _timed(vsync: 0, build: 1000, raster: 20000).copyWithNumber(1),
      _timed(vsync: 16667, build: 1000, raster: 1000).copyWithNumber(2),
      _timed(vsync: 33333, build: 1000, raster: 1000).copyWithNumber(3),
    ]);

    final report = probe.report();
    expect(report, contains('raster 20.0 | live: snapshot 1 | layers: '));
    expect(report, contains('over budget by thread: raster 1, ui 0'));
    expect(report, contains('  snapshot: 1/1 (100.0%)\n'));
  }, semanticsEnabled: false);

  test('scene counts pair enter with exit and never go negative', () {
    final probe = FrameProbe.instance
      ..exit('hero')
      ..enter('hero')
      ..enter('hero')
      ..exit('hero');
    probe
      ..start()
      ..beginUiFrame()
      ..endUiFrame(1)
      ..stop()
      ..exit('hero');
    probe.debugRecordTimings([_frame(40000).copyWithNumber(1)]);
    expect(probe.report(), contains('| live: hero 1 |'));
  });

  test('layer census counts only the offscreen kinds', () {
    final root = OffsetLayer()
      ..append(OpacityLayer(alpha: 128)..append(PictureLayer(Rect.zero)))
      ..append(OpacityLayer(alpha: 255))
      ..append(ImageFilterLayer())
      ..append(ClipRRectLayer(clipBehavior: Clip.antiAliasWithSaveLayer))
      ..append(ClipRRectLayer());
    final census = LayerCensus.ofLayer(root);
    expect(census.total, 7);
    expect(census.pictures, 1);
    expect(census.offscreen, {
      'opacity': 1,
      'imageFilter': 1,
      'saveLayerClip': 1,
    });
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
      ProviderScope(
        overrides: [
          imageWorkerProvider.overrideWithValue(stalledImageWorker()),
        ],
        child: MaterialApp(
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
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(FrameProbe.instance.recording, isFalse);
    // No image has needed the worker yet.
    expect(find.text('image worker: idle, starts 0/3'), findsOneWidget);
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
    // The copied report carries the worker's state too.
    expect(
      find.textContaining(RegExp(r'frames:[\s\S]*image worker: idle')),
      findsOneWidget,
    );
  });
}
