import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';

import 'haptics/app_haptics.dart';
import 'motion/motion_tokens.dart';
import 'scroll_behavior.dart';

/// The shared pull-to-refresh wrapper used by feed pages.
///
/// EasyRefresh owns the complete scroll/refresh lifecycle. [MaterialHeader]
/// runs with `clamping: false` on purpose: clamping pins the indicator while
/// the user reverses the pull, which leaves the icon stuck on screen while
/// the list scrolls; without clamping the indicator retracts with the
/// reverse gesture first, then the list starts moving — the expected
/// pull-to-refresh behaviour. Inside a NestedScrollView ([isNested])
/// EasyRefresh 4 only takes a clamping header; the list starts with
/// [nestedHeader], which pushes it down as far, and the NestedScrollView
/// runs [NestedRefreshOuterPhysics] so that header retracts before the
/// outer one collapses.
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
  /// already at the top (HCI 10). False when no mounted [PullToRefresh]
  /// was given [controller].
  static bool trigger(ScrollController controller) {
    final state = _mounted[controller];
    if (state == null) return false;
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

  /// Mounted wrappers by the controller of the list they wrap.
  static final _mounted = Expando<_PullToRefreshState>();

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

  @override
  void initState() {
    super.initState();
    _register(widget.scrollController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncOuter();
  }

  @override
  void didUpdateWidget(PullToRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      _unregister(oldWidget.scrollController);
      _register(widget.scrollController);
    }
    if (oldWidget.isNested != widget.isNested) _syncOuter();
  }

  @override
  void dispose() {
    _unregister(widget.scrollController);
    _leaveOuter();
    _controller.dispose();
    super.dispose();
  }

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
    final colors = Theme.of(context).colorScheme;
    final indicatorExit = MotionTokens.resolve(
      context,
      MotionTokens.refreshIndicatorExit,
    );
    final settings = (
      colors.primary,
      colors.surface,
      indicatorExit,
      widget.isNested,
      widget.scrollController,
    );
    if (settings != _refreshSettings) {
      _refreshSettings = settings;
      _refresh = _buildRefresh(colors, indicatorExit);
    }
    return _RefreshContent(content: widget.child, child: _refresh!);
  }

  EasyRefresh _buildRefresh(ColorScheme colors, Duration indicatorExit) {
    final isNested = widget.isNested;
    return EasyRefresh(
      header: BuilderHeader(
        // Keep EasyRefresh's 100dp arm threshold, but do not expose the
        // progress icon during the first few pixels of an ordinary scroll.
        // MaterialHeader paints as soon as overscroll starts; that makes a
        // tiny finger adjustment look like a refresh affordance. The icon
        // now fades in only after a deliberate pull while the underlying
        // trigger/retract state remains owned by EasyRefresh.
        triggerOffset: _triggerOffset,
        clamping: isNested,
        position: isNested
            ? IndicatorPosition.locator
            : IndicatorPosition.above,
        safeArea: !isNested,
        // This header owns the lifecycle; MaterialHeader below only paints.
        // Its default 1s hold would keep the list pulled down over an empty
        // gap long after the 200ms indicator exit — match the painter.
        processedDuration: indicatorExit,
        builder: (context, state) {
          final revealStart = 36.0;
          final revealRange = 20.0;
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
          return _ArmHaptics(
            mode: state.mode,
            child: Opacity(
              opacity: terminal,
              child: MaterialHeader(
                processedDuration: indicatorExit,
                triggerOffset: _triggerOffset,
                clamping: false,
                position: isNested
                    ? IndicatorPosition.locator
                    : IndicatorPosition.above,
                safeArea: !isNested,
                color: colors.primary,
                backgroundColor: colors.surface,
              ).build(context, state),
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

/// EasyRefresh's scroll behavior with the app's mouse scrollbar: its own
/// shows one on desktop only, so feeds on a tablet with a mouse had none.
class _FeedScrollBehavior extends ERScrollBehavior {
  _FeedScrollBehavior(ScrollPhysics? physics)
    : super(
        physics == null
            ? const ScrollPhysics()
            // Its _ERScrollPhysics is bouncing too. The refresh, edge and
            // fling behaviour stay EasyRefresh's: it finds its own physics
            // by walking the parent chain.
            : NoDragDeadZonePhysics(parent: physics),
      );

  /// A text control in the feed keeps the app's text physics instead of
  /// the refresh physics, which would let it drag (and arm the header).
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      textScrollPhysics(context) ?? super.getScrollPhysics(context);

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
