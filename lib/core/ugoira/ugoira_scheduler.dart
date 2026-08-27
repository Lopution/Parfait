import 'dart:async';

/// Monotonic, deadline-based Ugoira playback scheduler.
///
/// Production uses a short ticker to feed elapsed monotonic time into
/// [advance]. Tests can disable [autoTick] and advance the exact timeline
/// without sleeping. A pause preserves the remaining time in the current
/// frame; a visibility [stop] suspends activity while preserving play intent.
class UgoiraScheduler {
  UgoiraScheduler({
    required List<Duration> delays,
    required void Function(int index) onFrame,
    this.autoTick = true,
    this.tickInterval = const Duration(milliseconds: 16),
  }) : assert(delays.isNotEmpty),
       assert(tickInterval > Duration.zero),
       _delays = List.unmodifiable(delays),
       _onFrame = onFrame,
       _remaining = delays.first {
    if (delays.any((delay) => delay <= Duration.zero)) {
      throw ArgumentError.value(delays, 'delays', 'must all be positive');
    }
  }

  final List<Duration> _delays;
  final void Function(int index) _onFrame;
  final bool autoTick;
  final Duration tickInterval;

  Timer? _timer;
  Stopwatch? _stopwatch;
  Duration _remaining;
  int _currentIndex = 0;
  bool _isPlaying = false;
  bool _isActive = false;
  bool _disposed = false;

  int get currentIndex => _currentIndex;

  bool get isPlaying => _isPlaying;

  bool get isActive => _isActive;

  void play() {
    _ensureNotDisposed();
    _isPlaying = true;
    start();
  }

  void pause() {
    _ensureNotDisposed();
    _deactivate();
    _isPlaying = false;
  }

  /// Suspends ticking because the frame is not visible. The user intent to
  /// play is deliberately retained so [start] can resume it.
  void stop() {
    _ensureNotDisposed();
    _deactivate();
  }

  /// Resumes a previously playing scheduler after visibility/lifecycle
  /// returns. A paused scheduler remains paused.
  void start() {
    _ensureNotDisposed();
    if (!_isPlaying || _isActive) return;
    _isActive = true;
    if (!autoTick) return;
    _stopwatch = Stopwatch()..start();
    _timer = Timer.periodic(tickInterval, (_) {
      final stopwatch = _stopwatch;
      if (stopwatch == null || !_isActive) return;
      final elapsed = stopwatch.elapsed;
      stopwatch.reset();
      advance(elapsed);
    });
  }

  /// Advances the playback timeline. A delayed ticker may cross multiple
  /// frame deadlines; each crossed deadline is applied in order, so a jank
  /// interval cannot accumulate recursive-delay drift.
  void advance(Duration elapsed) {
    _ensureNotDisposed();
    if (!_isPlaying || !_isActive || elapsed <= Duration.zero) return;
    _remaining -= elapsed;
    while (_remaining <= Duration.zero) {
      _currentIndex = (_currentIndex + 1) % _delays.length;
      _onFrame(_currentIndex);
      if (!_isPlaying || !_isActive) return;
      _remaining += _delays[_currentIndex];
    }
  }

  void dispose() {
    if (_disposed) return;
    _deactivate();
    _disposed = true;
  }

  void _deactivate() {
    if (_isActive && autoTick) {
      final stopwatch = _stopwatch;
      if (stopwatch != null) {
        final elapsed = stopwatch.elapsed;
        stopwatch.reset();
        advance(elapsed);
      }
    }
    _isActive = false;
    _timer?.cancel();
    _timer = null;
    _stopwatch?.stop();
    _stopwatch = null;
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('ugoira scheduler is disposed');
  }
}
