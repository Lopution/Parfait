import 'dart:async';
import 'dart:math' as math;

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'haptics/app_haptics.dart';
import 'motion/motion_tokens.dart';
import 'scroll_behavior.dart';
import 'theme/func_semantic_tokens.dart';

/// Whether [context]'s render box belongs to an active, non-offstage, unclipped
/// subtree whose visible bounds intersect the current viewport.
bool isRenderBoxVisibleOnScreen(BuildContext context) {
  if (!context.mounted) return false;
  if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return false;
  final ro = context.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize || ro.size.isEmpty) return false;
  var visible = MatrixUtils.transformRect(
    ro.getTransformTo(null),
    Offset.zero & ro.size,
  );
  if (visible.isEmpty) return false;
  for (
    RenderObject? ancestor = ro.parent;
    ancestor != null;
    ancestor = ancestor.parent
  ) {
    if (ancestor is RenderOffstage && ancestor.offstage) return false;
    final Rect? localClip;
    if (ancestor is RenderClipRect &&
        ancestor.clipBehavior != Clip.none &&
        ancestor.hasSize) {
      localClip =
          ancestor.clipper?.getClip(ancestor.size) ??
          (Offset.zero & ancestor.size);
    } else if (ancestor is RenderClipRRect &&
        ancestor.clipBehavior != Clip.none &&
        ancestor.hasSize) {
      localClip =
          ancestor.clipper?.getClip(ancestor.size).outerRect ??
          (Offset.zero & ancestor.size);
    } else if (ancestor is RenderStack &&
        ancestor.clipBehavior != Clip.none &&
        ancestor.hasSize) {
      localClip = Offset.zero & ancestor.size;
    } else if (ancestor is RenderViewportBase &&
        ancestor.clipBehavior != Clip.none &&
        ancestor.hasSize) {
      localClip = Offset.zero & ancestor.size;
    } else {
      localClip = null;
    }
    if (localClip != null) {
      final clipGlobal = MatrixUtils.transformRect(
        ancestor.getTransformTo(null),
        localClip,
      );
      visible = visible.intersect(clipGlobal);
      if (visible.isEmpty) return false;
    }
  }
  final view = View.maybeOf(context);
  if (view == null) return true;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  return visible.overlaps(screen);
}

/// The shared pull-to-refresh wrapper used by feed pages.
///
/// EasyRefresh owns the complete scroll/refresh lifecycle. Non-nested lists
/// run with `clamping: false` on purpose: clamping pins the indicator while
/// the user reverses the pull, which leaves the icon stuck on screen while
/// the list scrolls; without clamping the indicator retracts with the
/// reverse gesture first, then the list starts moving — the expected
/// pull-to-refresh behaviour. Inside a NestedScrollView ([isNested])
/// EasyRefresh 4 only takes a clamping header; the list starts with
/// [nestedHeader], which pushes it down as far, and the NestedScrollView
/// runs [NestedRefreshOuterPhysics] so that header retracts before the
/// outer one collapses.
///
/// All platforms share the minimalist [SakuraRefreshIndicator] hairline ring.
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.isNested = false,
    this.scrollController,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final bool isNested;

  /// The controller of the list this wraps. Given, [PullToRefresh.trigger]
  /// can refresh that list as if the user had pulled it.
  final ScrollController? scrollController;

  /// Shows the indicator and refreshes the list [controller] scrolls, as a
  /// release past the trigger would — the bottom-bar re-tap on a list
  /// already at the top (HCI 10). Checks explicit [scrollController]
  /// registrations first, then active visible wrappers attached to a matching
  /// [PrimaryScrollController]. False when no matching [PullToRefresh] is
  /// mounted.
  static bool trigger(ScrollController controller) {
    final explicit = _mounted[controller];
    if (explicit != null &&
        explicit.mounted &&
        explicit._isActiveAndVisible()) {
      return _triggerState(explicit);
    }
    for (final state in _instances) {
      if (state.mounted &&
          state._effectiveController == controller &&
          state._isActiveAndVisible()) {
        return _triggerState(state);
      }
    }
    return false;
  }

  /// Whether an active visible [PullToRefresh] or [RefreshActionAnchor] is
  /// currently mounted for [focusContext] or the active route.
  static bool hasActiveRefresh([BuildContext? focusContext]) {
    if (focusContext != null && focusContext.mounted) {
      final primary = PrimaryScrollController.maybeOf(focusContext);
      if (primary != null && _hasController(primary)) return true;
    }
    for (final state in _instances) {
      if (state.mounted && state._isActiveAndVisible()) return true;
    }
    return _RefreshActionAnchorState.hasActive(focusContext);
  }

  static bool _hasController(ScrollController controller) {
    final explicit = _mounted[controller];
    if (explicit != null &&
        explicit.mounted &&
        explicit._isActiveAndVisible()) {
      return true;
    }
    for (final state in _instances) {
      if (state.mounted &&
          state._effectiveController == controller &&
          state._isActiveAndVisible()) {
        return true;
      }
    }
    return false;
  }

  /// Refreshes the currently active, visible [PullToRefresh], preferring
  /// [focusContext]'s [PrimaryScrollController] when present, falling back to
  /// any mounted active [RefreshActionAnchor]. False when nothing is active.
  static bool triggerActive([BuildContext? focusContext]) {
    if (focusContext != null && focusContext.mounted) {
      final primary = PrimaryScrollController.maybeOf(focusContext);
      if (primary != null && trigger(primary)) return true;
    }
    for (final state in _instances.toList().reversed) {
      if (state.mounted && state._isActiveAndVisible()) {
        return _triggerState(state);
      }
    }
    return _RefreshActionAnchorState.triggerActive(focusContext);
  }

  static bool _triggerState(_PullToRefreshState state) {
    final duration = MotionTokens.resolve(state.context, MotionTokens.chrome);
    unawaited(
      state._controller.callRefresh(
        // The overscroll a release would leave: just past the trigger.
        overOffset: _callRefreshOverOffset,
        // Null jumps there: reduced motion.
        duration: duration == Duration.zero ? null : duration,
        curve: MotionTokens.spatialCurve,
      ),
    );
    return true;
  }

  /// The first sliver of an [isNested] feed's list, where its header shows.
  /// It takes the header's height, so the list slides down under the tabs
  /// the way an ordinary feed's list follows the finger.
  static const nestedHeader = HeaderLocator.sliver(clearExtent: false);

  /// Mounted wrappers by the explicit controller of the list they wrap.
  static final _mounted = Expando<_PullToRefreshState>();

  /// All currently mounted wrappers, used to resolve visible feeds relying on
  /// [PrimaryScrollController] or triggered via keyboard refresh.
  static final _instances = <_PullToRefreshState>{};

  /// Mounted nested wrappers by their NestedScrollView's outer scrollable.
  static final _nestedByOuter = Expando<Set<_PullToRefreshState>>();

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

const _triggerOffset = 100.0;
const _callRefreshOverOffset = 20.0;

/// Header modes in which a refresh holds the header open, so a drag moves
/// the list rather than the header (EasyRefresh's `modeLocked`).
const _heldOpenModes = {IndicatorMode.processing, IndicatorMode.processed};

class _PullToRefreshState extends State<PullToRefresh> {
  final _controller = EasyRefreshController();
  ScrollableState? _outer;
  ScrollController? _primaryController;

  ScrollController? get _effectiveController =>
      widget.scrollController ?? _primaryController;

  @override
  void initState() {
    super.initState();
    PullToRefresh._instances.add(this);
    _register(widget.scrollController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _primaryController = widget.scrollController == null
        ? PrimaryScrollController.maybeOf(context)
        : null;
    _syncOuter();
  }

  @override
  void didUpdateWidget(PullToRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      _unregister(oldWidget.scrollController);
      _register(widget.scrollController);
      _primaryController = widget.scrollController == null
          ? PrimaryScrollController.maybeOf(context)
          : null;
    }
    if (oldWidget.isNested != widget.isNested) _syncOuter();
  }

  @override
  void dispose() {
    PullToRefresh._instances.remove(this);
    _unregister(widget.scrollController);
    _leaveOuter();
    _controller.dispose();
    super.dispose();
  }

  bool _isActiveAndVisible() => isRenderBoxVisibleOnScreen(context);

  /// Whether the user is dragging this nested feed's refresh header out, as
  /// EasyRefresh's own nested hold judges it.
  bool get _dragsHeader {
    final header = _controller.headerState;
    return header != null &&
        header.userOffsetNotifier.value &&
        header.offset > 0 &&
        !_heldOpenModes.contains(header.mode);
  }

  static bool _dragsHeaderUnder(ScrollContext outer) =>
      PullToRefresh._nestedByOuter[outer]?.any((state) => state._dragsHeader) ??
      false;

  void _syncOuter() {
    final outer = widget.isNested
        ? Scrollable.maybeOf(context, axis: Axis.vertical)
        : null;
    if (identical(outer, _outer)) return;
    _leaveOuter();
    _outer = outer;
    if (outer != null) {
      (PullToRefresh._nestedByOuter[outer] ??= {}).add(this);
    }
  }

  void _leaveOuter() {
    final outer = _outer;
    if (outer != null) PullToRefresh._nestedByOuter[outer]?.remove(this);
  }

  void _register(ScrollController? scrollController) {
    if (scrollController != null) {
      PullToRefresh._mounted[scrollController] = this;
    }
  }

  void _unregister(ScrollController? scrollController) {
    if (scrollController != null &&
        identical(PullToRefresh._mounted[scrollController], this)) {
      PullToRefresh._mounted[scrollController] = null;
    }
  }

  /// The [EasyRefresh] built for [_refreshSettings], kept while they hold.
  /// EasyRefresh syncs its nested host after every update, walking the
  /// whole list below it; a feed rebuilding for a new page or a load phase
  /// handed it a new widget each time. The list reaches it through
  /// [_RefreshContent] instead.
  EasyRefresh? _refresh;
  Object? _refreshSettings;

  Future<void> _onRefresh() => widget.onRefresh();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hairline =
        theme.extension<FuncSemanticTokens>()?.brandHairline ??
        theme.progressIndicatorTheme.circularTrackColor ??
        colors.outlineVariant;
    final indicatorExit = MotionTokens.resolve(
      context,
      MotionTokens.refreshIndicatorExit,
    );
    final settings = (
      colors.primary,
      hairline,
      indicatorExit,
      widget.isNested,
      widget.scrollController,
    );
    if (settings != _refreshSettings) {
      _refreshSettings = settings;
      _refresh = _buildRefresh(colors.primary, hairline, indicatorExit);
    }
    return _RefreshContent(content: widget.child, child: _refresh!);
  }

  EasyRefresh _buildRefresh(
    Color color,
    Color trackColor,
    Duration indicatorExit,
  ) {
    final isNested = widget.isNested;
    return EasyRefresh(
      header: BuilderHeader(
        // Keep EasyRefresh's 100dp arm threshold, but do not expose the
        // progress ring during the first few pixels of an ordinary scroll.
        // The ring fades in only after a deliberate pull while the underlying
        // trigger/retract state remains owned by EasyRefresh.
        triggerOffset: _triggerOffset,
        clamping: isNested,
        position: isNested
            ? IndicatorPosition.locator
            : IndicatorPosition.above,
        safeArea: !isNested,
        processedDuration: indicatorExit,
        builder: (context, state) {
          const revealStart = 36.0;
          const revealRange = 20.0;
          final pullOpacity = ((state.offset - revealStart) / revealRange)
              .clamp(0.0, 1.0);
          final terminal = switch (state.mode) {
            IndicatorMode.processing ||
            IndicatorMode.processed ||
            IndicatorMode.done ||
            IndicatorMode.ready ||
            IndicatorMode.armed => 1.0,
            _ => pullOpacity,
          };
          final active =
              state.mode != IndicatorMode.inactive && state.offset > 0;
          final padding =
              math.max(state.offset - SakuraRefreshIndicator.size, 0.0) / 2;
          return _ArmHaptics(
            mode: state.mode,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(width: double.infinity, height: state.offset),
                if (active)
                  Positioned(
                    bottom: padding,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Opacity(
                        opacity: terminal,
                        child: AnimatedScale(
                          duration: indicatorExit,
                          scale:
                              state.mode == IndicatorMode.processed ||
                                  state.mode == IndicatorMode.done
                              ? 0
                              : 1,
                          child: SakuraRefreshIndicator(
                            progress: (state.offset / state.actualTriggerOffset)
                                .clamp(0.0, 1.0),
                            spinning:
                                state.mode == IndicatorMode.ready ||
                                state.mode == IndicatorMode.processing,
                            color: color,
                            trackColor: trackColor,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      // Without onLoad EasyRefresh derives this from ClassicFooter, whose
      // infinite-scroll offset turns hitOver on: a fling then overshoots
      // the end and springs back up while the feed loads its next page.
      // Off, a fling stops at the end as it does at the top; a drag still
      // overscrolls both edges.
      notLoadFooter: const NotLoadFooter(hitOver: false),
      controller: _controller,
      scrollController: widget.scrollController,
      onRefresh: _onRefresh,
      isNested: isNested,
      scrollBehaviorBuilder: isNested
          ? _nestedScrollBehavior
          : _FeedScrollBehavior.new,
      child: const _RefreshContentSlot(),
    );
  }
}

/// Hands [PullToRefresh.child] past the kept [EasyRefresh] to
/// [_RefreshContentSlot].
class _RefreshContent extends InheritedWidget {
  const _RefreshContent({required this.content, required super.child});

  final Widget content;

  @override
  bool updateShouldNotify(_RefreshContent oldWidget) =>
      content != oldWidget.content;
}

class _RefreshContentSlot extends StatelessWidget {
  const _RefreshContentSlot();

  @override
  Widget build(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RefreshContent>()!.content;
}

ScrollBehavior _nestedScrollBehavior(ScrollPhysics? physics) =>
    _FeedScrollBehavior(
      physics == null ? null : _AppFlingPhysics(parent: physics),
    );

/// EasyRefresh's scroll behavior with per-platform drag devices, physics, and
/// mouse scrollbar: its own shows one on desktop only, so feeds on a tablet with
/// a mouse had none.
class _FeedScrollBehavior extends ERScrollBehavior {
  const _FeedScrollBehavior([this._feedPhysics])
    : super(_feedPhysics ?? const ScrollPhysics());

  final ScrollPhysics? _feedPhysics;

  @override
  Set<PointerDeviceKind> get dragDevices => platformDragDevices();

  /// A text control in the feed keeps the app's text physics instead of
  /// the refresh physics, which would let it drag (and arm the header).
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (textScrollPhysics(context) case final text?) return text;
    if (_feedPhysics == null) return const ScrollPhysics();
    return switch (getPlatform(context)) {
      TargetPlatform.iOS || TargetPlatform.macOS => _feedPhysics,
      _ => AndroidDragPhysics(parent: _feedPhysics),
    };
  }

  /// No edge effect, as EasyRefresh's own; the feed holds semantics while
  /// it scrolls, as every app scrollable does.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => ScrollSemanticsHold(child: child);

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => switch (getPlatform(context)) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => super.buildScrollbar(context, child, details),
    _ => mouseScrollbar(child, details),
  };
}

/// EasyRefresh's nested physics with the app's fling.
///
/// Inside a NestedScrollView EasyRefresh 4 flings with a
/// [ClampingScrollSimulation], while every other list and the profile's
/// outer scroll fling with [FuncScrollPhysics]. The coordinator runs one
/// simulation per position, so the two disagree: a light pull-down on a
/// collapsed profile stops in the feed instead of carrying on to expand
/// the header. Everything else, including the refresh trigger the
/// simulation call sets off, stays EasyRefresh's.
class _AppFlingPhysics extends ScrollPhysics {
  const _AppFlingPhysics({required ScrollPhysics super.parent});

  static const _fling = FuncScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );

  @override
  _AppFlingPhysics applyTo(ScrollPhysics? ancestor) =>
      _AppFlingPhysics(parent: buildParent(ancestor)!);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final simulation = super.createBallisticSimulation(position, velocity);
    if (simulation is! ClampingScrollSimulation) return simulation;
    return _fling.createBallisticSimulation(position, velocity);
  }
}

/// The outer physics of a NestedScrollView whose tabs refresh through a
/// nested [PullToRefresh]: the parent's, held while the user drags a tab's
/// refresh header out.
///
/// That header is clamping, so the feed stays at its top while it is out,
/// and the coordinator hands a reversed pull to the outer scroll first: the
/// header collapsed under an indicator stuck on screen. EasyRefresh holds
/// only an outer scroll that runs its own physics. Held, the outer scroll
/// passes the pull on to the feed, whose header retracts with the finger.
class NestedRefreshOuterPhysics extends ScrollPhysics {
  const NestedRefreshOuterPhysics({super.parent});

  @override
  NestedRefreshOuterPhysics applyTo(ScrollPhysics? ancestor) =>
      NestedRefreshOuterPhysics(parent: buildParent(ancestor));

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (value > position.pixels &&
        position is ScrollPosition &&
        _PullToRefreshState._dragsHeaderUnder(position.context)) {
      return value - position.pixels;
    }
    return super.applyBoundaryConditions(position, value);
  }
}

/// Registers an explicit refresh callback for secondary or non-scrollable
/// views that do not host a [PullToRefresh], allowing the desktop command bar
/// and F5 / Ctrl+R / Cmd+R shortcuts to refresh them uniformly.
class RefreshActionAnchor extends StatefulWidget {
  const RefreshActionAnchor({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final VoidCallback? onRefresh;
  final Widget child;

  @override
  State<RefreshActionAnchor> createState() => _RefreshActionAnchorState();
}

class _RefreshActionAnchorState extends State<RefreshActionAnchor> {
  static final List<_RefreshActionAnchorState> _anchors = [];

  static _RefreshActionAnchorState? _findActive([BuildContext? focusContext]) {
    if (focusContext != null && focusContext.mounted) {
      final focused = focusContext
          .findAncestorStateOfType<_RefreshActionAnchorState>();
      if (focused != null && focused._isActiveAndVisible()) {
        return focused;
      }
    }
    for (var i = _anchors.length - 1; i >= 0; i--) {
      final anchor = _anchors[i];
      if (anchor._isActiveAndVisible()) return anchor;
    }
    return null;
  }

  static bool hasActive([BuildContext? focusContext]) =>
      _findActive(focusContext) != null;

  static bool triggerActive([BuildContext? focusContext]) {
    final anchor = _findActive(focusContext);
    if (anchor == null) return false;
    anchor.widget.onRefresh?.call();
    return true;
  }

  bool _isActiveAndVisible() =>
      mounted &&
      widget.onRefresh != null &&
      isRenderBoxVisibleOnScreen(context);

  @override
  void initState() {
    super.initState();
    _anchors.add(this);
  }

  @override
  void dispose() {
    _anchors.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Plays the threshold haptics as the pull crosses the refresh trigger:
/// thresholdOn when it arms (releasing now refreshes), thresholdOff when
/// the user pulls back under it. Settling into the refresh after release
/// is silent — the arm haptic already told the user it will happen.
class _ArmHaptics extends StatefulWidget {
  const _ArmHaptics({required this.mode, required this.child});

  final IndicatorMode mode;
  final Widget child;

  @override
  State<_ArmHaptics> createState() => _ArmHapticsState();
}

class _ArmHapticsState extends State<_ArmHaptics> {
  @override
  void didUpdateWidget(_ArmHaptics oldWidget) {
    super.didUpdateWidget(oldWidget);
    final from = oldWidget.mode;
    final to = widget.mode;
    if (from != IndicatorMode.armed && to == IndicatorMode.armed) {
      AppHaptics.thresholdOn();
    } else if (from == IndicatorMode.armed && to == IndicatorMode.drag) {
      AppHaptics.thresholdOff();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Minimalist hairline sakura ring rendered by [PullToRefresh] across all
/// platforms (replaces Material's white floating disc).
class SakuraRefreshIndicator extends StatefulWidget {
  const SakuraRefreshIndicator({
    super.key,
    required this.progress,
    required this.spinning,
    required this.color,
    required this.trackColor,
  });

  static const double size = 24.0;
  static const double strokeWidth = 2.4;

  /// Normalized pull fraction in `[0, 1]` before [spinning] begins.
  final double progress;

  /// True while refresh work is in flight (`IndicatorMode.ready` or
  /// `IndicatorMode.processing`).
  final bool spinning;

  final Color color;
  final Color trackColor;

  @override
  State<SakuraRefreshIndicator> createState() => _SakuraRefreshIndicatorState();
}

class _SakuraRefreshIndicatorState extends State<SakuraRefreshIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinController = AnimationController(
    vsync: this,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpin();
  }

  @override
  void didUpdateWidget(SakuraRefreshIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning != widget.spinning) {
      _syncSpin();
    }
  }

  void _syncSpin() {
    final period = MotionTokens.resolve(context, MotionTokens.refreshSpin);
    if (widget.spinning && period > Duration.zero) {
      if (_spinController.duration != period) {
        _spinController.duration = period;
      }
      if (!_spinController.isAnimating) {
        _spinController.repeat();
      }
    } else if (_spinController.isAnimating) {
      _spinController.stop();
    }
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion =
        MotionTokens.resolve(context, MotionTokens.refreshSpin) ==
        Duration.zero;
    return AnimatedBuilder(
      animation: _spinController,
      builder: (context, _) {
        final rotation = widget.spinning && !reducedMotion
            ? _spinController.value * 2 * math.pi
            : 0.0;
        final sweep = widget.spinning
            ? 0.72 * 2 * math.pi
            : (0.15 + 0.70 * widget.progress.clamp(0.0, 1.0)) * 2 * math.pi;
        return CustomPaint(
          size: const Size.square(SakuraRefreshIndicator.size),
          painter: _SakuraRingPainter(
            rotation: rotation,
            sweep: sweep,
            color: widget.color,
            trackColor: widget.trackColor,
          ),
        );
      },
    );
  }
}

class _SakuraRingPainter extends CustomPainter {
  const _SakuraRingPainter({
    required this.rotation,
    required this.sweep,
    required this.color,
    required this.trackColor,
  });

  final double rotation;
  final double sweep;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = SakuraRefreshIndicator.strokeWidth;
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(center, radius, trackPaint);

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2 + rotation,
      sweep,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_SakuraRingPainter oldDelegate) =>
      oldDelegate.rotation != rotation ||
      oldDelegate.sweep != sweep ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor;
}
