import 'package:flutter/material.dart';

/// The one shared pull-to-refresh wrapper used by every feed.
///
/// It is deliberately thin. An earlier version ran its own scroll-notification
/// state machine next to Flutter's — a second drag-distance measurement, a
/// second threshold, and a hand-drawn indicator — and every U1 defect came out
/// of the two disagreeing: overscroll produced after the pointer lifted
/// reopened tracking, a pull that never armed never got a cancel callback so
/// the indicator stayed on screen, and a reverse drag moved the list without
/// moving the indicator because the framework owned the offset by then.
///
/// The threshold is now decided in exactly one place, and that place is the
/// framework. If a visual cannot be expressed through [RefreshIndicator],
/// drop the visual — not the correctness.
class PullToRefresh extends StatelessWidget {
  const PullToRefresh({super.key, required this.onRefresh, required this.child});

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: colors.primary,
      backgroundColor: colors.surface,
      strokeWidth: 3,
      child: child,
    );
  }
}
