import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent, SwipeEdge;
import 'package:flutter/widgets.dart';

import '../motion/motion_tokens.dart';
import '../widgets/home_branch_stack.dart' show BranchActivityScope;

/// Where a route's predictive back preview is.
enum BackPreviewPhase {
  /// No swipe: the route shows as it is.
  idle,

  /// The finger is on the swipe; the pose follows it.
  dragging,

  /// The swipe was cancelled; the pose eases back to rest.
  settling,

  /// The swipe was committed; the route pops from its pose.
  leaving,
}

/// A route's preview of Android's predictive back swipe (TRANS-04).
///
/// The route animation is not touched: it stays complete through the swipe,
/// and the commit is a plain pop, so every leave the back button runs (the
/// shared-element timeline, the Hero flight, the lifted bars) runs from the
/// posed layout. The pose ([BackPreviewPagePose], [BackPreviewSheetPose])
/// reads [value], the swipe's eased progress. Flutter's own predictive back
/// rewinds the route instead: a shared-element page's content would fade
/// with the finger, and a pop made while the navigator's gesture flag is up
/// starts no Hero flight.
class BackPreview extends ChangeNotifier {
  BackPreview(this.route);

  final ModalRoute<dynamic> route;

  /// Called as the preview starts and as it returns to rest; not as it
  /// leaves, which ends with the route.
  ValueChanged<bool>? onActiveChanged;

  BackPreviewPhase get phase => _phase;
  BackPreviewPhase _phase = BackPreviewPhase.idle;

  /// The swipe's progress through [MotionTokens.backPreviewProgress], 0 at
  /// rest; held where the finger let go once the route leaves.
  double get value => _progress?.value ?? 0;

  /// The edge the swipe came from: the pose moves away from it.
  SwipeEdge get edge => _edge;
  SwipeEdge _edge = SwipeEdge.left;

  /// How far the finger has moved up or down since the swipe began.
  double get verticalDrag => _verticalDrag;
  double _verticalDrag = 0;
  double? _startY;

  AnimationController? _progress;

  /// Whether a swipe may start a preview now: at rest, or settling back
  /// from a cancelled one.
  bool get canStart =>
      _phase == BackPreviewPhase.idle || _phase == BackPreviewPhase.settling;

  /// Whether the route is the one on screen: on top of its navigator, and
  /// that navigator in the branch on screen with nothing over the shell
  /// ([BranchActivityScope]). A route pushed over the shell mid-swipe (a
  /// shared image) takes it off screen before the commit.
  bool get onScreen {
    final navigator = route.navigator;
    if (navigator == null || !route.isCurrent) return false;
    return BranchActivityScope.maybeOf(navigator.context)?.active ?? true;
  }

  void start(PredictiveBackEvent event) {
    assert(canStart);
    final progress = _progress ??= AnimationController(vsync: route.navigator!)
      ..addListener(notifyListeners);
    final wasIdle = _phase == BackPreviewPhase.idle;
    // Before the stop: a settle cut short must not come to rest.
    _phase = BackPreviewPhase.dragging;
    progress.stop();
    _edge = event.swipeEdge;
    _startY = event.touchOffset?.dy;
    _verticalDrag = 0;
    if (wasIdle) {
      // The page below lays out and paints while this one shrinks.
      if (route.opaque) route.overlayEntries.first.opaque = false;
      onActiveChanged?.call(true);
    }
    _follow(event);
  }

  void update(PredictiveBackEvent event) {
    if (_phase != BackPreviewPhase.dragging) return;
    _follow(event);
  }

  void _follow(PredictiveBackEvent event) {
    final y = event.touchOffset?.dy;
    if (y != null && _startY != null) _verticalDrag = y - _startY!;
    _progress!.value = MotionTokens.backPreviewProgress.transform(
      event.progress,
    );
    notifyListeners();
  }

  /// Eases the pose back to rest over [duration], then covers the page
  /// below again.
  void cancel(Duration duration) {
    if (_phase != BackPreviewPhase.dragging) return;
    _phase = BackPreviewPhase.settling;
    notifyListeners();
    _progress!
        .animateTo(
          0,
          duration: duration,
          curve: MotionTokens.backPreviewCancelCurve,
        )
        .whenCompleteOrCancel(() {
          if (_phase == BackPreviewPhase.settling) _rest();
        });
  }

  /// Pops the route from its pose. A route no longer [onScreen], or that
  /// would not pop now, goes back to rest; one that would not pop hears
  /// the back as the button's (its `PopScope` asks).
  void commit() {
    if (_phase != BackPreviewPhase.dragging) return;
    if (!onScreen) {
      _rest();
      return;
    }
    final navigator = route.navigator!;
    if (route.popDisposition == RoutePopDisposition.doNotPop) {
      _rest();
      navigator.maybePop();
      return;
    }
    _phase = BackPreviewPhase.leaving;
    notifyListeners();
    try {
      navigator.pop();
    } catch (_) {
      _rest();
      rethrow;
    }
    // A pop the router turned down (a route's exit check) left it on top.
    if (route.isCurrent) _rest();
  }

  void _rest() {
    if (_disposed) return;
    _progress?.stop();
    _progress?.value = 0;
    _phase = BackPreviewPhase.idle;
    if (route.opaque && route.animation!.isCompleted) {
      route.overlayEntries.first.opaque = true;
    }
    onActiveChanged?.call(false);
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _progress?.dispose();
    super.dispose();
  }
}

/// Takes Android's predictive back swipe for its [preview]'s route when
/// that route is on top of the screen and would pop: not a button event,
/// motion not reduced, the route current and `popGestureEnabled` (no
/// `PopScope` holding it, not first, not animating), and its navigator in
/// the branch on screen with nothing over the shell ([BranchActivityScope]).
/// Any other route lets the swipe through; with no taker the binding pops
/// on the commit as the back button does.
class BackPreviewListener extends StatefulWidget {
  const BackPreviewListener({
    super.key,
    required this.preview,
    required this.child,
  });

  final BackPreview preview;
  final Widget child;

  @override
  State<BackPreviewListener> createState() => _BackPreviewListenerState();
}

class _BackPreviewListenerState extends State<BackPreviewListener>
    with WidgetsBindingObserver {
  /// Read in build: the swipe arrives outside one.
  Duration _cancelDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The binding sends update, cancel and commit only to observers that
  // returned true from start.
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final preview = widget.preview;
    if (backEvent.isButtonEvent ||
        _cancelDuration == Duration.zero ||
        !preview.canStart ||
        !preview.onScreen ||
        !preview.route.popGestureEnabled) {
      return false;
    }
    preview.start(backEvent);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) =>
      widget.preview.update(backEvent);

  @override
  void handleCancelBackGesture() => widget.preview.cancel(_cancelDuration);

  @override
  void handleCommitBackGesture() => widget.preview.commit();

  @override
  Widget build(BuildContext context) {
    _cancelDuration = MotionTokens.resolve(
      context,
      MotionTokens.backPreviewCancel,
    );
    return widget.child;
  }
}

/// A page's predictive back pose, Android's in-app shared-element values:
/// down to 90 % about its centre, moved away from the swiped edge by
/// `w / 20 − 8`, up or down with the finger by at most `h / 20 − 8`, its
/// corners rounding to the display's. Held where the finger let go while
/// the page leaves. At rest it paints its child as it is: no layer, no
/// clip.
///
/// It goes inside the route's page (`buildPage`): a Hero measures its
/// flight's start in the page's own subtree, so a pose around the page
/// would send the image off from where it was before the swipe. A layer
/// of the transition that must shrink with the page (a shared-element
/// page's background) takes a pose of its own: the same box, the same
/// transform.
class BackPreviewPagePose extends StatelessWidget {
  const BackPreviewPagePose({
    super.key,
    required this.preview,
    required this.child,
  });

  final BackPreview preview;
  final Widget child;

  static const double _minScale = 0.9;
  static const double _fallbackCornerRadius = 32;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final corners =
        MediaQuery.displayCornerRadiiOf(context) ??
        const BorderRadius.all(Radius.circular(_fallbackCornerRadius));
    return ListenableBuilder(
      listenable: preview,
      builder: (context, child) {
        final t = preview.value;
        final drag = preview.verticalDrag;
        final yMax = _shift(size.height);
        final y =
            Curves.easeOut.transform(
              (drag.abs() / size.height).clamp(0.0, 1.0),
            ) *
            drag.sign *
            yMax;
        final scale = 1 - (1 - _minScale) * t;
        final transform = Matrix4.identity()
          ..translateByDouble(
            _awaySign(preview) * _shift(size.width) * t,
            y * t,
            0,
            1,
          )
          ..scaleByDouble(scale, scale, 1, 1);
        return Transform(
          transform: transform,
          alignment: Alignment.center,
          child: ClipRRect(
            borderRadius: BorderRadius.lerp(BorderRadius.zero, corners, t)!,
            clipBehavior: t > 0 ? Clip.antiAlias : Clip.none,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// A page committed from its back preview, around its transition: it
/// fades out and carries on away from the swiped edge over the first part
/// of its leave ([MotionTokens.backPreviewLeave]), as the texture the leave
/// paints. A shared-element page leaves on its own timeline instead.
class BackPreviewLeave extends StatelessWidget {
  const BackPreviewLeave({
    super.key,
    required this.preview,
    required this.route,
    required this.child,
  });

  final BackPreview preview;

  /// The route's controller, 1 → 0 as it leaves.
  final Animation<double> route;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ListenableBuilder(
      listenable: Listenable.merge([preview, route]),
      builder: (context, child) {
        final away = preview.phase == BackPreviewPhase.leaving
            ? MotionTokens.backPreviewLeave.transform(1 - route.value)
            : 0.0;
        return Transform.translate(
          offset: Offset(_awaySign(preview) * _shift(width) * away, 0),
          child: Opacity(opacity: 1 - away, child: child),
        );
      },
      child: child,
    );
  }
}

/// `w / 20 − 8`: how far the pose moves along a side of length [extent].
double _shift(double extent) => math.max(0, extent / 20 - 8);

/// Away from the swiped edge.
double _awaySign(BackPreview preview) =>
    preview.edge == SwipeEdge.right ? -1 : 1;

/// A bottom sheet's predictive back pose, MDC's bottom container: the
/// sheet narrows by up to 48 dp and shortens by up to 24 dp from its
/// bottom edge, and its content ([BackPreviewSheetContent]) scales back
/// by the difference, so it shrinks without stretching. The leave is the
/// sheet's own dismiss, from the pose.
class BackPreviewSheetPose extends StatelessWidget {
  const BackPreviewSheetPose({
    super.key,
    required this.preview,
    required this.child,
  });

  final BackPreview preview;

  /// The route's page: the sheet at its bottom.
  final Widget child;

  @override
  Widget build(BuildContext context) => _SheetPoseScope(
    preview: preview,
    child: ListenableBuilder(
      listenable: preview,
      builder: (context, child) {
        final (scaleX, scaleY) = _sheetScale(preview);
        return Transform(
          transform: Matrix4.diagonal3Values(scaleX, scaleY, 1),
          alignment: Alignment.bottomCenter,
          child: child,
        );
      },
      child: child,
    ),
  );
}

/// The sheet's content inside the [BackPreviewSheetPose] of its route:
/// marked for the pose to find its sheet, scaled back to keep its shape. Outside one it
/// is [child] as it is.
class BackPreviewSheetContent extends StatelessWidget {
  const BackPreviewSheetContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final preview = context
        .getInheritedWidgetOfExactType<_SheetPoseScope>()
        ?.preview;
    if (preview == null) return child;
    return _SheetContentMark(
      preview: preview,
      child: ListenableBuilder(
        listenable: preview,
        builder: (context, child) {
          final (scaleX, scaleY) = _sheetScale(preview);
          return Transform(
            transform: Matrix4.diagonal3Values(1, scaleX / scaleY, 1),
            alignment: Alignment.topCenter,
            child: child,
          );
        },
        child: child,
      ),
    );
  }
}

/// Each sheet's content, from which its surface is found.
final _sheetContents = Expando<RenderBox>();

/// The sheet's surface: the Material it draws, the nearest physical layer
/// over its content. Null before its first layout.
Size? _sheetSize(BackPreview preview) {
  final content = _sheetContents[preview];
  if (content == null || !content.attached) return null;
  for (RenderObject? node = content.parent; node != null; node = node.parent) {
    if (node is RenderPhysicalShape || node is RenderPhysicalModel) {
      return (node as RenderBox).size;
    }
  }
  assert(false, 'A sheet in a back preview draws no Material surface.');
  return null;
}

(double, double) _sheetScale(BackPreview preview) {
  const maxNarrow = 48.0;
  const maxShorten = 24.0;
  final t = preview.value;
  if (t == 0) return (1, 1);
  final size = _sheetSize(preview);
  if (size == null || size.isEmpty) return (1, 1);
  // A sheet shorter than the shrink would turn over: it halves at most.
  const minScale = 0.5;
  return (
    math.max(minScale, 1 - maxNarrow / size.width * t),
    math.max(minScale, 1 - maxShorten / size.height * t),
  );
}

class _SheetPoseScope extends InheritedWidget {
  const _SheetPoseScope({required this.preview, required super.child});

  final BackPreview preview;

  @override
  bool updateShouldNotify(_SheetPoseScope oldWidget) =>
      preview != oldWidget.preview;
}

class _SheetContentMark extends SingleChildRenderObjectWidget {
  const _SheetContentMark({required this.preview, super.child});

  final BackPreview preview;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSheetContentMark(preview);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSheetContentMark renderObject,
  ) {
    renderObject.preview = preview;
    _sheetContents[preview] = renderObject;
  }
}

class _RenderSheetContentMark extends RenderProxyBox {
  _RenderSheetContentMark(this.preview);

  BackPreview preview;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sheetContents[preview] = this;
  }
}
