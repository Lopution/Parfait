import 'dart:collection';

import 'package:flutter/gestures.dart';

/// Whether the app resamples touch moves to its frames ([TouchResampler]).
/// A build with `--dart-define=PIXIV_TOUCH_RESAMPLE=false` dispatches every
/// move as it arrives, for a side-by-side feel check.
const kTouchResample = bool.fromEnvironment(
  'PIXIV_TOUCH_RESAMPLE',
  defaultValue: true,
);

/// How far before the frame's vsync a touch is sampled. Android's
/// `InputConsumer` constants, as are the three below: a few milliseconds
/// of latency make room to interpolate between two real samples instead of
/// predicting.
const kResampleLatency = Duration(milliseconds: 5);

/// Two samples closer than this are too noisy to resample between.
const kResampleMinInterval = Duration(milliseconds: 2);

/// Past this gap between the last two samples the finger's speed is stale:
/// no prediction.
const kResampleMaxInterval = Duration(milliseconds: 20);

/// The furthest a prediction reaches past the newest sample, and never more
/// than half the gap between the last two.
const kResampleMaxPrediction = Duration(milliseconds: 8);

/// Hands a finger's moves to the app once per frame, at where the finger
/// was [kResampleLatency] before the frame's vsync, as Android's
/// `InputConsumer` does for every native view.
///
/// Flutter's Android embedding dispatches each touch event the moment it
/// arrives, and a frame takes the last one in. Touch sampling and the
/// display drift against each other, so one frame gets a sample 1 ms old
/// and the next one 7 ms old: per-frame movement goes uneven while every
/// frame is on time.
///
/// Each frame ([sample]) dispatches the real moves up to the sample time,
/// then one move at the sample time, between the newest real sample and the
/// next one, or predicted from the last two within Android's limits. That
/// move is marked [PointerEvent.synthesized]: gesture recognizers leave it
/// out of their velocity, as Android's `VelocityTracker` skips resampled
/// samples, so a fling leaves at the speed of the real samples. A real
/// sample that turns up no later than a prediction already shown is not
/// dispatched: the finger stays where it was shown instead of stepping
/// back.
///
/// Every other event goes out at once ([add]), after the moves still
/// queued: a down is never delayed, and an up or cancel lands where the
/// finger last was.
class TouchResampler {
  TouchResampler({required this.dispatch, required this.requestFrame});

  /// Delivers an event to the app.
  final void Function(PointerEvent event) dispatch;

  /// Asks for a frame: a queued move goes out on the next one.
  final void Function() requestFrame;

  final _pointers = <int, _Pointer>{};

  /// Whether a move waits for a frame.
  bool get hasPending => _pointers.values.any((p) => p.queue.isNotEmpty);

  /// Takes in [event]. A finger's move waits for its frame while [queue]
  /// holds (frames are running); anything else goes out at once, after the
  /// moves still queued.
  void add(PointerEvent event, {bool queue = true}) {
    final touch = event.kind == PointerDeviceKind.touch;
    if (touch && event is PointerMoveEvent) {
      final pointer = _pointers[event.pointer] ??= _Pointer(
        event.timeStamp,
        event.position - event.delta,
      );
      if (queue) {
        pointer.queue.add(event);
        requestFrame();
        return;
      }
      flush();
      _dispatchReal(pointer, event);
      return;
    }
    flush();
    dispatch(event);
    if (!touch) return;
    switch (event) {
      case PointerDownEvent():
        _pointers[event.pointer] = _Pointer(event.timeStamp, event.position);
      case PointerUpEvent() || PointerCancelEvent():
        _pointers.remove(event.pointer);
      default:
    }
  }

  /// Dispatches the moves due at a frame whose vsync is [frameTime], on the
  /// clock of the events' time stamps.
  void sample(Duration frameTime) {
    final sampleTime = frameTime - kResampleLatency;
    for (final pointer in _pointers.values.toList()) {
      final queue = pointer.queue;
      PointerMoveEvent? newest;
      while (queue.isNotEmpty && queue.first.timeStamp <= sampleTime) {
        newest = queue.removeFirst();
        _dispatchReal(pointer, newest);
      }
      if (newest != null) _dispatchResampled(pointer, newest, sampleTime);
    }
  }

  /// Dispatches every queued move as it came, oldest first.
  void flush() {
    while (true) {
      _Pointer? oldest;
      for (final pointer in _pointers.values) {
        final head = pointer.queue.firstOrNull;
        if (head == null) continue;
        if (oldest == null || head.timeStamp < oldest.queue.first.timeStamp) {
          oldest = pointer;
        }
      }
      if (oldest == null) return;
      _dispatchReal(oldest, oldest.queue.removeFirst());
    }
  }

  void _dispatchReal(_Pointer pointer, PointerMoveEvent event) {
    pointer.record(event.timeStamp, event.position);
    final shownUntil = pointer.resampledAt;
    if (shownUntil != null && event.timeStamp <= shownUntil) return;
    pointer.resampledAt = null;
    _dispatch(
      pointer,
      event,
      event.timeStamp,
      event.position,
      event.synthesized,
    );
  }

  void _dispatchResampled(
    _Pointer pointer,
    PointerMoveEvent newest,
    Duration sampleTime,
  ) {
    final at = _resample(pointer, sampleTime);
    if (at == null || at.position == pointer.shown) return;
    pointer.resampledAt = at.time;
    _dispatch(pointer, newest, at.time, at.position, true);
  }

  /// Where [pointer] was at [sampleTime], by Android's rules; null when
  /// the samples do not support a guess.
  static _Sample? _resample(_Pointer pointer, Duration sampleTime) {
    final current = pointer.current;
    final next = pointer.queue.firstOrNull;
    final _Sample from;
    final _Sample to;
    var time = sampleTime;
    if (next != null) {
      from = current;
      to = (time: next.timeStamp, position: next.position);
      if (to.time - from.time < kResampleMinInterval) return null;
    } else {
      final previous = pointer.previous;
      if (previous == null) return null;
      from = previous;
      to = current;
      final interval = to.time - from.time;
      if (interval < kResampleMinInterval || interval > kResampleMaxInterval) {
        return null;
      }
      final halfInterval = interval ~/ 2;
      final limit =
          to.time +
          (halfInterval < kResampleMaxPrediction
              ? halfInterval
              : kResampleMaxPrediction);
      if (time > limit) time = limit;
    }
    if (time == current.time) return null;
    final t =
        (time - from.time).inMicroseconds /
        (to.time - from.time).inMicroseconds;
    return (time: time, position: Offset.lerp(from.position, to.position, t)!);
  }

  void _dispatch(
    _Pointer pointer,
    PointerMoveEvent template,
    Duration time,
    Offset position,
    bool synthesized,
  ) {
    final delta = position - pointer.shown;
    pointer.shown = position;
    dispatch(
      template.copyWith(
        timeStamp: time,
        position: position,
        delta: delta,
        synthesized: synthesized,
      ),
    );
  }
}

typedef _Sample = ({Duration time, Offset position});

class _Pointer {
  _Pointer(Duration time, Offset position)
    : current = (time: time, position: position),
      shown = position;

  /// Moves waiting for their frame, oldest first.
  final queue = Queue<PointerMoveEvent>();

  /// The newest real sample taken in and the one before it.
  _Sample current;
  _Sample? previous;

  /// Where the app last saw the pointer.
  Offset shown;

  /// When the resampled position the app last saw was taken; null once a
  /// later real sample went out.
  Duration? resampledAt;

  void record(Duration time, Offset position) {
    previous = current;
    current = (time: time, position: position);
  }
}
