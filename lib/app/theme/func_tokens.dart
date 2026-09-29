import 'package:material_ui/material_ui.dart';

abstract final class FuncTokens {
  static const Color primary = Color(0xFFFF6289);

  static const Color darkBackground = Color(0xFF181818);
  static const Color darkText = Color(0xFFD5D5D5);
  static const Color darkSubdued = Color(0xFF606163);

  /// Secondary *text* must stay readable (the low-alpha subdued colors are
  /// for borders/dividers and were never meant to carry glyphs).
  static const Color darkTextSecondary = Color(0xFFA8A8AD);

  static const Color lightBackground = Color(0xFFFFFFFF);
  static const Color lightText = Color(0xFF383838);
  static const Color lightSubdued = Color(0x40383838);
  static const Color lightTextSecondary = Color(0xFF64646A);

  static const Color transparent = Color(0x00000000);
  static const Color error = Color(0xFFF44336);
  static const Color imageOverlay = Color(0x3DFFFFFF);

  /// Container ladder above the page ([lightBackground]/[darkBackground],
  /// also `surface`/`surfaceContainerLowest`). Each higher step moves away
  /// from the page — darker in light, lighter in dark — so layered surfaces
  /// (cards → dialogs → pickers) stay distinguishable on both themes.
  static const Color lightContainerLow = Color(0xFFF9F9FA);
  static const Color lightContainer = Color(0xFFF3F3F5);
  static const Color lightContainerHigh = Color(0xFFEDEDEF);
  static const Color lightContainerHighest = Color(0xFFE7E7E9);
  static const Color darkContainerLow = Color(0xFF1F2022);
  static const Color darkContainer = Color(0xFF252628);
  static const Color darkContainerHigh = Color(0xFF303135);
  static const Color darkContainerHighest = Color(0xFF3A3B3F);

  /// Inverted surface for transient chrome (SnackBar) so it stands apart
  /// from both the page and the containers on it.
  static const Color lightInverseSurface = Color(0xFF303034);
  static const Color darkInverseSurface = Color(0xFFE4E4E7);
  static const Color lightOnInverseSurface = lightContainer;
  static const Color darkOnInverseSurface = lightInverseSurface;

  /// Hairline separators; intentionally fainter than the subdued text tint.
  static const Color darkDivider = Color(0x1FD5D5D5);
  static const Color lightDivider = Color(0x1F383838);

  /// Scrim/overlay tone for dimming content under floating surfaces.
  static const Color surfaceOverlay = Color(0x52000000);

  /// Controls floating over artwork (ImageOverlayButton, page counters):
  /// dark enough that white glyphs keep 4.5:1 even over a pure white image.
  static const Color imageControl = Color(0x8C000000);
  static const Color onImageControl = lightBackground;

  /// Generic status tones; domain-specific aliases keep one literal each.
  static const Color success = Color(0xFF388E3C);
  static const Color warning = Color(0xFFF57C00);
  static const Color danger = error;

  static const Color networkProbeDnsWarning = Color(0xFFEF6C00);
  static const Color networkProbeSuccess = success;
  static const Color networkProbeWarning = warning;
  static const Color networkProbeError = Color(0xFFD32F2F);
  static const Color networkProbeEch = Color(0xFF00796B);
  static const Color networkProbeNoSni = Color(0xFF303F9F);
  static const Color networkProbeNeutral = Color(0xFF616161);
}
