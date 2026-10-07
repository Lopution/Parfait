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
class PullToRefresh extends StatelessWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.isNested = false,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final bool isNested;

  @override
  Widget build(BuildContext context) {
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
        triggerOffset: 100,
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
                triggerOffset: 100,
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
      onRefresh: onRefresh,
      isNested: isNested,
      child: child,
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
