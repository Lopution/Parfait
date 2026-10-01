import 'dart:math' as math;
import 'dart:ui' show FramePhase, SemanticsUpdate;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// `--dart-define=PIXIV_FRAME_PROBE=true` exposes the probe's settings
/// entry in release builds — the only way to attach it to a signed
/// measurement package. Default builds leave the define unset, so release
/// behaviour is unchanged.
const bool kPixivFrameProbe = bool.fromEnvironment('PIXIV_FRAME_PROBE');

/// Dev-only frame timing probe for scroll-jank investigation.
///
/// Records [FrameTiming] samples via [SchedulerBinding.addTimingsCallback]
/// while [recording] is true, then summarizes build/raster distributions into
/// a copyable report. Registered only in debug/profile builds — release code
/// never instantiates this (the settings entry is gated on [kReleaseMode],
/// with [kPixivFrameProbe] as the deliberate release exception).
///
/// Per-frame data is kept verbatim (not aggregated online) so the report can
/// slice by arbitrary percentile and dump the raw tail if a single giant
/// frame is the interesting bit.
class FrameProbe {
  FrameProbe._();

  static final FrameProbe instance = FrameProbe._();

  final List<FrameTiming> _frames = [];
  bool _attached = false;

  /// UI-thread phase breakdown per engine frame number, filled by the app
  /// binding's hooks. Insertion-ordered, so the oldest entry drops first in
  /// step with [_frames].
  final Map<int, UiFrame> _uiFrames = {};

  /// The frame between `handleBeginFrame` and the end of `handleDrawFrame`.
  UiFrame? _open;

  /// Collects work measured between frames; it explains the next frame's
  /// late start, so it is handed to that frame when it begins.
  UiFrame _pending = UiFrame();

  /// Keeps one quiet stretch from piling up events without bound.
  static const int _maxEventsPerFrame = 16;

  /// Recording survives the control page closing (dispose does not stop), so
  /// a forgotten session must not grow memory without bound: keep at most
  /// [maxFrames] samples and drop the oldest (FIFO). At ~120fps this still
  /// covers ~80s of scrolling — far longer than a meaningful sample pass.
  static const int maxFrames = 10000;

  bool get recording => _attached;
  int get frameCount => _frames.length;

  /// True once the buffer hit [maxFrames]; the status bar uses this to show
  /// that the oldest frames are being dropped.
  bool get isFull => _frames.length >= maxFrames;

  void start() {
    if (_attached) return;
    _frames.clear();
    _uiFrames.clear();
    _open = null;
    _pending = UiFrame();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _attached = true;
  }

  void stop() {
    if (!_attached) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _attached = false;
    _open = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
    final overflow = _frames.length - maxFrames;
    if (overflow > 0) {
      _frames.removeRange(0, overflow);
    }
  }

  /// Binding hook: a frame's `handleBeginFrame` is about to run.
  void beginUiFrame() {
    if (!_attached) return;
    _open = _pending;
    _pending = UiFrame();
  }

  /// Binding hook: the frame's `handleDrawFrame` finished. The engine frame
  /// number is only published between the two halves, so the frame is filed
  /// here, where it matches [FrameTiming.frameNumber].
  void endUiFrame(int frameNumber) {
    final frame = _open;
    _open = null;
    if (!_attached || frame == null) return;
    _uiFrames[frameNumber] = frame;
    if (_uiFrames.length > maxFrames) _uiFrames.remove(_uiFrames.keys.first);
  }

  /// Runs [body], adding its duration to [phase] of the open frame. A plain
  /// call when nothing is recording.
  void timePhase(UiPhase phase, VoidCallback body) {
    final frame = _open;
    if (frame == null) {
      body();
      return;
    }
    final watch = Stopwatch()..start();
    try {
      body();
    } finally {
      frame.add(phase, watch.elapsedMicroseconds);
    }
  }

  /// Runs [body] and, while recording, logs it under [label] against the
  /// frame it delayed: the open frame, or the next one when it ran between
  /// frames.
  T measure<T>(String label, T Function() body) {
    if (!_attached) return body();
    final watch = Stopwatch()..start();
    try {
      return body();
    } finally {
      final micros = watch.elapsedMicroseconds;
      final open = _open;
      final events = open?.during ?? _pending.before;
      if (events.length < _maxEventsPerFrame) {
        events.add('$label ${_ms(micros)}');
      }
    }
  }

  /// Test seam: feed timings without scheduling real frames.
  @visibleForTesting
  void debugRecordTimings(List<FrameTiming> timings) => _onTimings(timings);

  /// Test seam: drop the recorded buffer without touching the scheduler.
  @visibleForTesting
  void debugClearTimings() {
    _frames.clear();
    _uiFrames.clear();
  }

  /// Assumed panel rate when the display does not report one.
  static const double _fallbackRefreshRate = 60;

  /// Vsync gaps longer than this are idle time (nothing animating), not a
  /// stalled frame, and stay out of the interval distribution.
  static const _idleGap = Duration(milliseconds: 250);

  /// How many of the slowest frames the report breaks down.
  static const int _slowestListed = 8;

  String report() {
    final buffer = StringBuffer()
      ..writeln('# frame probe')
      ..writeln('frames: ${_frames.length}');
    if (_frames.isEmpty) {
      buffer.writeln('(no frames recorded — scroll while recording)');
      return buffer.toString();
    }

    final reportedRate =
        SchedulerBinding
            .instance
            .platformDispatcher
            .implicitView
            ?.display
            .refreshRate ??
        0;
    final knownRate = reportedRate.isFinite && reportedRate > 0;
    final refreshRate = knownRate ? reportedRate : _fallbackRefreshRate;
    // UI and raster threads are pipelined: a frame misses its vsync when
    // either stage alone exceeds one refresh interval of the actual panel.
    final budget = Duration(microseconds: (1e6 / refreshRate).round());
    final slowest = _frames
        .map(
          (f) => f.buildDuration > f.rasterDuration
              ? f.buildDuration
              : f.rasterDuration,
        )
        .toList();
    final overBudget = slowest.where((d) => d > budget).length;

    final builds = _frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final rasters = _frames.map((f) => f.rasterDuration.inMicroseconds).toList()
      ..sort();
    final totals = _frames.map((f) => f.totalSpan.inMicroseconds).toList()
      ..sort();

    buffer
      ..writeln(
        'display: ${refreshRate.toStringAsFixed(0)}Hz'
        '${knownRate ? '' : ' (not reported, assumed)'}'
        ', frame budget ${(budget.inMicroseconds / 1000).toStringAsFixed(1)}ms',
      )
      ..writeln(
        'over budget: $overBudget '
        '(${(overBudget * 100 / _frames.length).toStringAsFixed(1)}%)'
        '  >2x budget: ${slowest.where((d) => d > budget * 2).length}',
      )
      ..writeln(_line('build', builds))
      ..writeln(_line('raster', rasters))
      ..writeln(_line('total', totals));
    // Vsync-to-vsync spacing while animating: p50 shows the rate frames are
    // actually delivered at (a throttled panel reads 2x the budget), the
    // tail shows skipped vsyncs whatever thread caused them.
    final intervals = _activeIntervals();
    if (intervals.isNotEmpty) buffer.writeln(_line('interval', intervals));

    // A frame that starts late lost its time before build: the UI thread
    // was busy with work outside the frame (or vsync arrived late).
    final lateStarts = _frames.where((f) => f.vsyncOverhead > budget).length;
    buffer
      ..writeln('late start (wait > budget): $lateStarts')
      ..writeln(
        'semantics: '
        '${SemanticsBinding.instance.semanticsEnabled ? 'on' : 'off'}',
      )
      ..writeln('slowest frames (ms):');
    final ranked = [..._frames]
      ..sort((a, b) => b.totalSpan.compareTo(a.totalSpan));
    for (final frame in ranked.take(_slowestListed)) {
      buffer.writeln('  ${_breakdown(frame)}');
    }

    final cache = PaintingBinding.instance.imageCache;
    buffer.writeln(
      'imageCache: ${cache.currentSize} entries / '
      '${(cache.currentSizeBytes / 1024 / 1024).toStringAsFixed(1)}MB, '
      'live ${cache.liveImageCount}, pending ${cache.pendingImageCount}',
    );
    return buffer.toString();
  }

  /// One slow frame end to end: wait for the UI thread, UI work (split by
  /// phase when the binding hooks saw it), wait for the raster thread,
  /// raster — plus the measured work that ran just before or inside it.
  String _breakdown(FrameTiming timing) {
    final queue =
        timing.timestampInMicroseconds(FramePhase.rasterStart) -
        timing.timestampInMicroseconds(FramePhase.buildFinish);
    final line = StringBuffer(
      '${_ms(timing.totalSpan.inMicroseconds)} = '
      'wait ${_ms(timing.vsyncOverhead.inMicroseconds)} + '
      'ui ${_ms(timing.buildDuration.inMicroseconds)}',
    );
    final ui = _uiFrames[timing.frameNumber];
    if (ui != null) line.write(' [${ui.phases()}]');
    line.write(
      ' + queue ${_ms(queue)} + raster ${_ms(timing.rasterDuration.inMicroseconds)}',
    );
    if (ui != null && ui.before.isNotEmpty) {
      line.write(' | before: ${ui.before.join(', ')}');
    }
    if (ui != null && ui.during.isNotEmpty) {
      line.write(' | during: ${ui.during.join(', ')}');
    }
    return line.toString();
  }

  List<int> _activeIntervals() {
    final intervals = <int>[];
    for (var i = 1; i < _frames.length; i++) {
      final gap =
          _frames[i].timestampInMicroseconds(FramePhase.vsyncStart) -
          _frames[i - 1].timestampInMicroseconds(FramePhase.vsyncStart);
      if (gap > 0 && gap <= _idleGap.inMicroseconds) intervals.add(gap);
    }
    return intervals..sort();
  }

  static String _line(String label, List<int> sortedMicros) {
    return '$label: p50 ${_percentile(sortedMicros, 0.5)}ms  '
        'p90 ${_percentile(sortedMicros, 0.9)}ms  '
        'p99 ${_percentile(sortedMicros, 0.99)}ms  '
        'max ${sortedMicros.last / 1000}ms';
  }

  static double _percentile(List<int> sorted, double q) {
    final index = math.min(sorted.length - 1, (sorted.length * q).floor());
    return sorted[index] / 1000;
  }
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(1);

/// UI-thread stages of one frame, as the app binding times them.
enum UiPhase {
  /// `handleBeginFrame`: tickers, animations, scroll simulations.
  animate,

  /// The binding's `drawFrame`: build, layout, paint, composite, semantics.
  draw,

  /// Root pipeline owner flushes, nested inside [draw].
  layout,
  paint,
  semantics,

  /// The whole `handleDrawFrame`: [draw] plus post-frame callbacks.
  frame,
}

/// Measured UI-thread time of one frame, in microseconds, and the measured
/// work that ran right before it (between frames) or inside it.
class UiFrame {
  final Map<UiPhase, int> _micros = {};
  final List<String> before = [];
  final List<String> during = [];

  void add(UiPhase phase, int micros) =>
      _micros[phase] = (_micros[phase] ?? 0) + micros;

  int operator [](UiPhase phase) => _micros[phase] ?? 0;

  /// `anim / build / layout / paint / sem / post`, where build is the part
  /// of draw the pipeline flushes do not account for (it includes the small
  /// compositing step) and post is what ran after draw.
  String phases() {
    final draw = this[UiPhase.draw];
    final flushed =
        this[UiPhase.layout] + this[UiPhase.paint] + this[UiPhase.semantics];
    return 'anim ${_ms(this[UiPhase.animate])} '
        'build ${_ms(math.max(0, draw - flushed))} '
        'layout ${_ms(this[UiPhase.layout])} '
        'paint ${_ms(this[UiPhase.paint])} '
        'sem ${_ms(this[UiPhase.semantics])} '
        'post ${_ms(math.max(0, this[UiPhase.frame] - draw))}';
  }
}

/// Root pipeline owner that times its flushes for [FrameProbe]. Stands in
/// for the framework's default root owner (which manages no render node of
/// its own) only in builds that can record; the flushes still recurse into
/// the views' child owners exactly as before.
final class ProbedRootPipelineOwner extends PipelineOwner {
  ProbedRootPipelineOwner() : super(onSemanticsUpdate: _noRootSemantics);

  // The root owner has no root node, so it never produces semantics.
  static void _noRootSemantics(SemanticsUpdate _) {}

  @override
  void flushLayout() =>
      FrameProbe.instance.timePhase(UiPhase.layout, () => super.flushLayout());

  @override
  void flushCompositingBits() => FrameProbe.instance.timePhase(
    UiPhase.paint,
    () => super.flushCompositingBits(),
  );

  @override
  void flushPaint() =>
      FrameProbe.instance.timePhase(UiPhase.paint, () => super.flushPaint());

  @override
  void flushSemantics() => FrameProbe.instance.timePhase(
    UiPhase.semantics,
    () => super.flushSemantics(),
  );
}
