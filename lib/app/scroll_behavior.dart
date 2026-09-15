import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// App-wide scroll behavior: on desktop the mouse and trackpad drag like
/// touch (Flutter's default excludes them, leaving wheel-only scrolling).
/// Wheel smoothing itself is per-scrollable — see `SmoothWheelScroll`.
///
/// Touch physics follow the EasyRefresh convention app-wide: feed pages get
/// their feel from `_ERScrollPhysics` (a `BouncingScrollPhysics` with an
/// always-scrollable parent and no platform overscroll glow), and before
/// this every other page ran platform `ClampingScrollPhysics` instead — one
/// app, two physics stacks. Mirroring the same base physics here keeps
/// detail/settings/search pages, profile NestedScrollView outer scrolls and
/// feed scrolls on a single scheme.
class FuncScrollBehavior extends MaterialScrollBehavior {
  const FuncScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
