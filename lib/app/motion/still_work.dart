import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/image/image_worker_providers.dart';

/// Work a screen does ahead of the user, such as building the tab or page
/// next to the one on screen, held back until nothing on the screen moves:
/// building a page costs a frame or two, which a still screen hides and a
/// swipe, a scroll or a transition shows.
///
/// [runStillWork] runs on a frame after which
/// - the screen is visible (its [TickerMode] is on: not a hidden branch,
///   not under another route),
/// - no finger is down: a held or slowly dragging finger keeps no
///   animation running,
/// - no scrollable reported through [trackStillScroll] is scrolling,
/// - the on-screen images have loaded, failed ones included, when
///   [stillWorkWaitsForImages]: they come first on the network, and
/// - no animation runs, waiting at most [maxAnimationFrames], since a
///   looping indicator never stops.
///
/// One piece per still frame: after a piece, the gate waits for the frame
/// that builds it and asks again. [runStillWork] picks its piece when it
/// runs, so work the user has moved past is never done.
mixin StillWork<T extends StatefulWidget> on State<T> {
  /// Frames to wait for running animations to stop.
  static const maxAnimationFrames = 60;

  /// Does one piece of the deferred work; returns whether it did any.
  bool runStillWork();

  /// Whether the work also waits for the images on screen.
  bool get stillWorkWaitsForImages => true;

  ValueListenable<TickerModeData>? _visible;
  ValueListenable<int>? _imageLoads;
  final _scrolling = <BuildContext>{};
  var _scheduled = false;
  var _checkQueued = false;
  var _animationFrames = 0;

  @override
  void initState() {
    super.initState();
    _Pointers.instance.addListener(_wake);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.getValuesNotifier(context);
    if (!identical(visible, _visible)) {
      _visible?.removeListener(_wake);
      _visible = visible..addListener(_wake);
    }
    if (stillWorkWaitsForImages && _imageLoads == null) {
      _imageLoads = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(imageWorkerProvider).foregroundLoads..addListener(_wake);
    }
  }

  @override
  void dispose() {
    _Pointers.instance.removeListener(_wake);
    _visible?.removeListener(_wake);
    _imageLoads?.removeListener(_wake);
    super.dispose();
  }

  /// Asks for [runStillWork] on the next still frame.
  void scheduleStillWork() {
    if (_scheduled) return;
    _scheduled = true;
    _animationFrames = 0;
    _wake();
  }

  /// Hand to a [NotificationListener] above the scrollables whose motion
  /// holds the work back.
  bool trackStillScroll(ScrollNotification notification) {
    switch (notification) {
      case ScrollStartNotification(:final context?):
        _scrolling.add(context);
      case ScrollEndNotification(:final context?):
        _scrolling.remove(context);
        _wake();
      default:
    }
    return false;
  }

  void _wake() {
    if (!_scheduled || _checkQueued || !mounted) return;
    _checkQueued = true;
    SchedulerBinding.instance
      ..addPostFrameCallback(_check)
      ..scheduleFrame();
  }

  void _check(Duration _) {
    _checkQueued = false;
    if (!mounted || !_scheduled) return;
    // A scrollable gone mid-scroll never reports its end.
    _scrolling.removeWhere((context) => !context.mounted);
    // Each of these wakes the gate when it clears.
    if (!(_visible?.value.enabled ?? true) ||
        _Pointers.instance.anyDown ||
        _scrolling.isNotEmpty ||
        (_imageLoads?.value ?? 0) > 0) {
      return;
    }
    final scheduler = SchedulerBinding.instance;
    if (scheduler.transientCallbackCount > 0 &&
        _animationFrames++ < maxAnimationFrames) {
      // A running animation brings the next frame.
      _checkQueued = true;
      scheduler.addPostFrameCallback(_check);
      return;
    }
    _scheduled = false;
    if (runStillWork()) scheduleStillWork();
  }
}

/// Whether a pointer is down anywhere in the app; notifies when the last
/// one lifts.
class _Pointers extends ChangeNotifier {
  _Pointers._() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
  }

  static final instance = _Pointers._();

  final _down = <int>{};

  bool get anyDown => _down.isNotEmpty;

  void _route(PointerEvent event) {
    switch (event) {
      case PointerDownEvent():
        _down.add(event.pointer);
      case PointerUpEvent() || PointerCancelEvent():
        if (_down.remove(event.pointer) && _down.isEmpty) notifyListeners();
    }
  }
}
