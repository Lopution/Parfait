import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/log.dart';
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

/// The only caller of `SystemChrome.setEnabledSystemUIMode`. A platform
/// failure (desktop embedders, a detached engine) is logged, never thrown
/// and never silently dropped. Only [Exception]s are platform failures —
/// a programming error still throws.
Future<void> setSystemUiMode(SystemUiMode mode) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(mode);
  } on Exception catch (error) {
    log('setEnabledSystemUIMode($mode) failed: $error');
  }
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
