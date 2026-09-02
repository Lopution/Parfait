import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';

/// The shared pull-to-refresh wrapper used by feed pages.
///
/// EasyRefresh owns the complete scroll/refresh lifecycle. In particular, its
/// clamping header keeps the indicator's travel separate from the list's
/// scroll offset: while the user reverses a pull, the header retracts first
/// and the list only starts moving after the indicator is gone. This is the
/// interaction used by PixEz as well as the one required by our feeds.
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
      header: MaterialHeader(
        position: isNested
            ? IndicatorPosition.locator
            : IndicatorPosition.above,
        safeArea: !isNested,
        clamping: true,
        color: colors.primary,
        backgroundColor: colors.surface,
      ),
      onRefresh: onRefresh,
      isNested: isNested,
      child: child,
    );
  }
}
