import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';

import 'haptics/app_haptics.dart';
import 'motion/motion_tokens.dart';

/// The shared pull-to-refresh wrapper used by feed pages.
///
/// EasyRefresh owns the complete scroll/refresh lifecycle. [MaterialHeader]
/// runs with `clamping: false` on purpose: clamping pins the indicator while
/// the user reverses the pull, which leaves the icon stuck on screen while
/// the list scrolls; without clamping the indicator retracts with the
/// reverse gesture first, then the list starts moving — the expected
/// pull-to-refresh behaviour.
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
    final duration = MotionTokens.resolve(state.context, MotionTokens.fast);
    unawaited(
      state._controller.callRefresh(
        // The overscroll a release would leave: just past the trigger.
        overOffset: _callRefreshOverOffset,
        // Null jumps there: reduced motion.
        duration: duration == Duration.zero ? null : duration,
        curve: MotionTokens.fastCurve,
      ),
    );
    return true;
  }

  /// Mounted wrappers by the controller of the list they wrap.
  static final _mounted = Expando<_PullToRefreshState>();

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

const _triggerOffset = 100.0;
const _callRefreshOverOffset = 20.0;

class _PullToRefreshState extends State<PullToRefresh> {
  final _controller = EasyRefreshController();

  @override
  void initState() {
    super.initState();
    _register(widget.scrollController);
  }

  @override
  void didUpdateWidget(PullToRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      _unregister(oldWidget.scrollController);
      _register(widget.scrollController);
    }
  }

  @override
  void dispose() {
    _unregister(widget.scrollController);
    _controller.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final isNested = widget.isNested;
    final colors = Theme.of(context).colorScheme;
    final indicatorExit = MotionTokens.resolve(
      context,
      MotionTokens.refreshIndicatorExit,
    );
    return EasyRefresh(
      header: BuilderHeader(
        // Keep EasyRefresh's 100dp arm threshold, but do not expose the
        // progress icon during the first few pixels of an ordinary scroll.
        // MaterialHeader paints as soon as overscroll starts; that makes a
        // tiny finger adjustment look like a refresh affordance. The icon
        // now fades in only after a deliberate pull while the underlying
        // trigger/retract state remains owned by EasyRefresh.
        triggerOffset: _triggerOffset,
        clamping: false,
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
      onRefresh: widget.onRefresh,
      isNested: isNested,
      child: widget.child,
    );
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
