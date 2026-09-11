import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// App-wide scroll behavior: on desktop the mouse and trackpad drag like
/// touch (Flutter's default excludes them, leaving wheel-only scrolling).
/// Wheel smoothing itself is per-scrollable — see `SmoothWheelScroll`.
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
}
