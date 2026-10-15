import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// One line of card text, described exactly as the card lays it out.
typedef WarmText = ({String text, TextStyle style, Locale? locale});

/// Lays out feed card text between frames, ahead of the frame that builds
/// the card.
///
/// Laying out a glyph for the first time reads its outline from the font
/// file, and on a phone short of memory the pages of rarely used glyphs (the
/// kanji of a Japanese title) are often evicted: the read was a 2–5 ms wait
/// on storage inside the frame that built the card, which then missed its
/// vsync. Skia keeps the glyph's metrics once read, so laying the same text
/// out once beforehand moves the read out of the frame. RecyclerView does
/// the same with its prefetch, binding upcoming items between frames.
///
/// One paragraph runs per gap between frames, right after a frame ends, and
/// only when the frame left room for a slow one before the next vsync.
class FeedTextWarmup {
  FeedTextWarmup({Duration Function()? clock}) : _now = clock ?? _monotonicNow;

  /// The longest a cold paragraph took on device, its font pages read back
  /// from flash.
  static const itemCost = Duration(microseconds: 5500);

  /// One vsync at 120 Hz. A slower display only gets a wider margin; the
  /// reported refresh rate is not trusted, as LTPO panels switch rates.
  static const vsync = Duration(microseconds: 8333);

  static final _stopwatch = Stopwatch()..start();
  static Duration _monotonicNow() => _stopwatch.elapsed;

  final Duration Function() _now;
  final _pending = Queue<_Pending>();
  int? _frameCallback;
  Timer? _gap;
  bool _waiting = false;
  bool _disposed = false;

  /// Queues [texts] behind any still pending.
  void add(
    Iterable<WarmText> texts, {
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    assert(!_disposed);
    for (final text in texts) {
      if (text.text.isEmpty) continue;
      _pending.add(_Pending(text, textScaler, textDirection));
    }
    _schedule();
  }

  /// Drops everything still pending (the feed was replaced).
  void clear() => _pending.clear();

  @visibleForTesting
  int get pendingCount => _pending.length;

  void dispose() {
    _disposed = true;
    final frameCallback = _frameCallback;
    if (frameCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frameCallback);
    }
    _gap?.cancel();
    _pending.clear();
  }

  void _schedule() {
    if (_waiting || _pending.isEmpty || _disposed) return;
    _waiting = true;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.idle) {
      // Mid-frame, its start unknown: look again once it is over.
      scheduler.addPostFrameCallback((_) {
        if (!_disposed) _runInGap(null);
      }, debugLabel: 'FeedTextWarmup');
    } else if (scheduler.hasScheduledFrame) {
      // Note when the coming frame starts, and run right after it ends.
      _frameCallback = scheduler.scheduleFrameCallback((_) {
        _frameCallback = null;
        final frameStart = _now();
        scheduler.addPostFrameCallback((_) {
          if (!_disposed) _runInGap(frameStart);
        }, debugLabel: 'FeedTextWarmup');
      }, scheduleNewFrame: false);
    } else {
      _runInGap(null);
    }
  }

  void _runInGap(Duration? frameStart) =>
      _gap = Timer(Duration.zero, () => _runOne(frameStart));

  void _runOne(Duration? frameStart) {
    _waiting = false;
    if (_disposed || _pending.isEmpty) return;
    if (_fits(frameStart)) _layout(_pending.removeFirst());
    _schedule();
  }

  /// Whether a paragraph started now ends before the next frame is due.
  bool _fits(Duration? frameStart) {
    if (!SchedulerBinding.instance.hasScheduledFrame) return true;
    if (frameStart == null) return false;
    return _now() - frameStart + itemCost <= vsync;
  }

  static void _layout(_Pending item) {
    assert(SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle);
    final text = item.text;
    TextPainter(
        text: TextSpan(text: text.text, style: text.style),
        locale: text.locale,
        textDirection: item.textDirection,
        textScaler: item.textScaler,
        maxLines: 1,
      )
      ..layout()
      ..dispose();
  }
}

class _Pending {
  const _Pending(this.text, this.textScaler, this.textDirection);

  final WarmText text;
  final TextScaler textScaler;
  final TextDirection textDirection;
}
