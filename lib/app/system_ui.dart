import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'theme/func_tokens.dart';

/// The only file that may construct `SystemUiOverlayStyle` / write
/// `AnnotatedRegion<SystemUiOverlayStyle>` / call `SystemChrome` (design §6,
/// enforced by test/architecture/feedback_channels_test.dart).

/// Transparent status and navigation bars whose icons contrast with
/// [background] — the brightness of what is painted under the bars.
SystemUiOverlayStyle funcSystemBarsStyle(Brightness background) {
  final icons = background == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: FuncTokens.transparent,
    // iOS reads the *bar's* brightness and derives icon colour itself.
    statusBarBrightness: background,
    statusBarIconBrightness: icons,
    systemNavigationBarColor: FuncTokens.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarDividerColor: FuncTokens.transparent,
    // systemNavigationBarContrastEnforced stays unset: with three-button
    // navigation the platform decides whether to add a scrim.
  );
}

/// Scoped system bar style: the root default, or a page override while it
/// is mounted. Built on [AnnotatedRegion], so leaving the page restores the
/// style underneath without any imperative reset — `RenderView` picks the
/// innermost region covering each bar, which is this page while it fills
/// the screen and the root style again the frame after it unmounts.
class FuncSystemBars extends StatelessWidget {
  const FuncSystemBars({
    super.key,
    required this.background,
    required this.child,
  });

  /// Brightness of what paints under the bars; icons take the inverse.
  final Brightness background;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: funcSystemBarsStyle(background),
      child: child,
    );
  }
}
