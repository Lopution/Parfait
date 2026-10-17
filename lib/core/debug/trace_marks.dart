import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Marks in the system trace that tell what the user was doing: the page on
/// screen and its tab, scenes in progress (`enter`/`exit`), probe events
/// (`event`) and every pointer (`down`, `up`, `cancel`). Each is a zero-length timeline
/// slice named `parfait <label>`, which a profile build hands to Perfetto,
/// so a free session on a device can be read back as "this frame janked on
/// that page, right after that fling".
///
/// Off in release builds: there `Timeline` records nothing and no pointer
/// route is attached.
abstract final class TraceMarks {
  static const bool enabled = !kReleaseMode;

  /// Where marks go; tests swap it for a recorder.
  @visibleForTesting
  static void Function(String label) sink = _toTimeline;

  static void _toTimeline(String label) {
    Timeline.startSync('parfait $label');
    Timeline.finishSync();
  }

  static void mark(String label) {
    if (enabled) sink(label);
  }

  static String? _page;

  /// Marks [location] as the page on screen when it changed.
  static void page(String location) {
    if (!enabled || location == _page) return;
    _page = location;
    sink('page $location');
  }

  /// Marks [label] as the tab now selected on the page: tabs share their
  /// page's route, so only this tells them apart.
  static void tab(String label) => mark('tab $label');

  static final Map<int, _PointerTrack> _pointers = {};
  static bool _tracking = false;

  /// Marks every pointer from now on. An `up` carries how far the pointer
  /// moved since its `down` and how fast it left, in dp and dp/s: enough to
  /// tell a tap from a drag from a fling.
  static void trackPointers() {
    if (!enabled || _tracking) return;
    _tracking = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  /// Detaches the pointer route and forgets the last page and the sink.
  @visibleForTesting
  static void debugReset() {
    if (_tracking) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      _tracking = false;
    }
    _pointers.clear();
    _page = null;
    sink = _toTimeline;
  }

  static void _onPointer(PointerEvent event) {
    switch (event) {
      case PointerDownEvent():
        _pointers[event.pointer] = _PointerTrack(event);
        sink('down');
      case PointerMoveEvent():
        _pointers[event.pointer]?.add(event);
      case PointerUpEvent():
        final track = _pointers.remove(event.pointer);
        if (track == null) return;
        track.add(event);
        sink(
          'up ${track.distance(event).round()}dp '
          '${track.speed().round()}dp/s',
        );
      case PointerCancelEvent():
        if (_pointers.remove(event.pointer) != null) sink('cancel');
    }
  }
}

class _PointerTrack {
  _PointerTrack(PointerDownEvent down)
    : _start = down.position,
      _velocity = VelocityTracker.withKind(down.kind) {
    add(down);
  }

  final Offset _start;
  final VelocityTracker _velocity;

  void add(PointerEvent event) =>
      _velocity.addPosition(event.timeStamp, event.position);

  double distance(PointerEvent end) => (end.position - _start).distance;

  double speed() => _velocity.getVelocity().pixelsPerSecond.distance;
}
