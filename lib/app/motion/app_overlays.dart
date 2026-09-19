import 'package:material_ui/material_ui.dart';

import 'motion_tokens.dart';

/// App-wide modal bottom sheet entry: one presentation curve and one
/// reduced-motion gate for every sheet. Under reduced motion the sheet
/// snaps open via [AnimationStyle.noAnimation] — the state change still
/// lands, only the slide is removed.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool showDragHandle = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    sheetAnimationStyle: MotionTokens.enabled(context)
        ? AnimationStyle(
            duration: MotionTokens.sheet,
            curve: MotionTokens.sheetCurve,
          )
        : AnimationStyle.noAnimation,
    builder: builder,
  );
}

/// Alert/confirm dialog counterpart of [showAppBottomSheet]: one entry so
/// every dialog shares [MotionTokens.dialog] and the same reduced-motion
/// gate (zero duration, no transition).
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String? barrierLabel,
  bool useRootNavigator = true,
}) {
  return showDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    useRootNavigator: useRootNavigator,
    animationStyle: MotionTokens.enabled(context)
        ? AnimationStyle(duration: MotionTokens.dialog)
        : AnimationStyle.noAnimation,
  );
}
