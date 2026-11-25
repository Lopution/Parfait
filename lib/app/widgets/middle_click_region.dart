import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:material_ui/material_ui.dart';

/// Fires [onMiddleClick] when a pointer presses and releases
/// [kMiddleMouseButton] within this widget's bounds.
///
/// Leaves primary-button gestures (`Ctrl+Click` / `Cmd+Click` batch selection
/// per `FEED-24`) and secondary-button context menus completely untouched.
class MiddleClickRegion extends StatefulWidget {
  const MiddleClickRegion({
    super.key,
    required this.onMiddleClick,
    required this.child,
  });

  final VoidCallback? onMiddleClick;
  final Widget child;

  @override
  State<MiddleClickRegion> createState() => _MiddleClickRegionState();
}

class _MiddleClickRegionState extends State<MiddleClickRegion> {
  int? _middlePointer;

  @override
  Widget build(BuildContext context) {
    final handler = widget.onMiddleClick;
    if (handler == null) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if ((event.buttons & kMiddleMouseButton) != 0) {
          _middlePointer = event.pointer;
        }
      },
      onPointerUp: (event) {
        if (_middlePointer == event.pointer) {
          _middlePointer = null;
          handler();
        }
      },
      onPointerCancel: (event) {
        if (_middlePointer == event.pointer) {
          _middlePointer = null;
        }
      },
      child: widget.child,
    );
  }
}
