import 'dart:math' as math;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _attached = true;
  }

  void stop() {
    if (!_attached) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _attached = false;
  }

  void _onTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
    final overflow = _frames.length - maxFrames;
    if (overflow > 0) {
      _frames.removeRange(0, overflow);
    }
  }

  /// Test seam: feed timings without scheduling real frames.
  @visibleForTesting
  void debugRecordTimings(List<FrameTiming> timings) => _onTimings(timings);

  /// Test seam: drop the recorded buffer without touching the scheduler.
  @visibleForTesting
  void debugClearTimings() => _frames.clear();

  /// Assumed panel rate when the display does not report one.
  static const double _fallbackRefreshRate = 60;

  /// Vsync gaps longer than this are idle time (nothing animating), not a
  /// stalled frame, and stay out of the interval distribution.
  static const _idleGap = Duration(milliseconds: 250);

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

    final worst = totals.last;
    final worstFrame = _frames.firstWhere(
      (f) => f.totalSpan.inMicroseconds == worst,
    );
    buffer.writeln(
      'worst: total ${worst / 1000}ms '
      '(build ${worstFrame.buildDuration.inMicroseconds / 1000}ms, '
      'raster ${worstFrame.rasterDuration.inMicroseconds / 1000}ms)',
    );

    final cache = PaintingBinding.instance.imageCache;
    buffer.writeln(
      'imageCache: ${cache.currentSize} entries / '
      '${(cache.currentSizeBytes / 1024 / 1024).toStringAsFixed(1)}MB, '
      'live ${cache.liveImageCount}, pending ${cache.pendingImageCount}',
    );
    return buffer.toString();
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
