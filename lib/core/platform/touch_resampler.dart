import 'dart:collection';

import 'package:flutter/gestures.dart';

/// Whether the app resamples touch moves to its frames ([TouchResampler]).
/// A build with `--dart-define=PIXIV_TOUCH_RESAMPLE=false` dispatches every
/// move as it arrives, for a side-by-side feel check.
const kTouchResample = bool.fromEnvironment(
  'PIXIV_TOUCH_RESAMPLE',
  defaultValue: true,
);

/// How far before the frame's vsync a touch is sampled: about one 120 Hz
/// touch interval plus the time a sample takes to arrive, so the sample
/// after the sampling time is usually in by the frame. Android samples
/// 5 ms back and predicts the rest; this one does not predict.
const kResampleLatency = Duration(milliseconds: 10);

/// Two samples closer than this are too noisy to interpolate between
/// (Android's `RESAMPLE_MIN_DELTA`).
const kResampleMinInterval = Duration(milliseconds: 2);

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
/// next one. Without a next sample the frame keeps the newest real one:
/// unlike Android this never predicts, because a recognizer takes every
/// move it gets as an observation. A predicted point the finger did not
/// follow would bend a scale's velocity, and a real sample arriving behind
/// a prediction could only step the finger back or go missing from the
/// fling speed.
///
/// The interpolated move is marked [PointerEvent.synthesized], so drag
/// recognizers leave it out of their velocity, as Android's
/// `VelocityTracker` skips resampled samples: a fling leaves at the speed
/// of the real samples.
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
      while (queue.isNotEmpty && queue.first.timeStamp <= sampleTime) {
        _dispatchReal(pointer, queue.removeFirst());
      }
      // Also on a frame that took no new sample: a touch rate below the
      // display's still moves every frame.
      final next = queue.firstOrNull;
      if (next != null) _interpolate(pointer, next, sampleTime);
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
    pointer.last = (time: event.timeStamp, position: event.position);
    _dispatch(
      pointer,
      event,
      event.timeStamp,
      event.position,
      event.synthesized,
    );
  }

  /// Dispatches where [pointer] was at [sampleTime], between its newest real
  /// sample and [next].
  void _interpolate(
    _Pointer pointer,
    PointerMoveEvent next,
    Duration sampleTime,
  ) {
    final last = pointer.last;
    final interval = next.timeStamp - last.time;
    if (sampleTime <= last.time || interval < kResampleMinInterval) return;
    final t = (sampleTime - last.time).inMicroseconds / interval.inMicroseconds;
    final position = Offset.lerp(last.position, next.position, t)!;
    if (position == pointer.shown) return;
    _dispatch(pointer, next, sampleTime, position, true);
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

class _Pointer {
  _Pointer(Duration time, Offset position)
    : last = (time: time, position: position),
      shown = position;

  /// Moves waiting for their frame, oldest first.
  final queue = Queue<PointerMoveEvent>();

  /// The newest real sample dispatched.
  ({Duration time, Offset position}) last;

  /// Where the app last saw the pointer.
  Offset shown;
}
