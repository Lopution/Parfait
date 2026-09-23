import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

/// Dev-only frame timing probe for scroll-jank investigation.
///
/// Records [FrameTiming] samples via [SchedulerBinding.addTimingsCallback]
/// while [recording] is true, then summarizes build/raster distributions into
/// a copyable report. Registered only in debug/profile builds — release code
/// never instantiates this (the settings entry is gated on [kReleaseMode]).
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

  /// Jank threshold: one 60Hz vsync interval. On 90/120Hz panels this is a
  /// lenient bar — frames are also bucketed by >2 intervals so high-refresh
  /// jank still surfaces in the >33ms bucket.
  static const _jank = Duration(microseconds: 16670);

  String report() {
    final buffer = StringBuffer()
      ..writeln('# frame probe')
      ..writeln('frames: ${_frames.length}');
    if (_frames.isEmpty) {
      buffer.writeln('(no frames recorded — scroll while recording)');
      return buffer.toString();
    }

    final builds = _frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final rasters = _frames.map((f) => f.rasterDuration.inMicroseconds).toList()
      ..sort();
    final totals = _frames.map((f) => f.totalSpan.inMicroseconds).toList()
      ..sort();

    buffer
      ..writeln(
        'jank>16.7ms: ${_frames.where((f) => f.totalSpan > _jank).length}'
        '  >33ms: ${_frames.where((f) => f.totalSpan > _jank * 2).length}',
      )
      ..writeln(_line('build', builds))
      ..writeln(_line('raster', rasters))
      ..writeln(_line('total', totals));

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
