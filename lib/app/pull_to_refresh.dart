import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';

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
          return Opacity(
            opacity: terminal,
            child: MaterialHeader(
              triggerOffset: 100,
              clamping: false,
              position: isNested
                  ? IndicatorPosition.locator
                  : IndicatorPosition.above,
              safeArea: !isNested,
              color: colors.primary,
              backgroundColor: colors.surface,
            ).build(context, state),
          );
        },
      ),
      onRefresh: onRefresh,
      isNested: isNested,
      child: child,
    );
  }
}
