import 'package:material_ui/material_ui.dart';

abstract final class FuncTokens {
  static const Color primary = Color(0xFFFF6289);

  static const Color darkBackground = Color(0xFF181818);
  static const Color darkSurface = Color(0xFF252628);
  static const Color darkText = Color(0xFFD5D5D5);
  static const Color darkSubdued = Color(0xFF606163);

  /// Secondary *text* must stay readable (the low-alpha subdued colors are
  /// for borders/dividers and were never meant to carry glyphs).
  static const Color darkTextSecondary = Color(0xFF9C9CA1);

  static const Color lightBackground = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFE9E9EA);
  static const Color lightText = Color(0xFF383838);
  static const Color lightSubdued = Color(0x40383838);
  static const Color lightTextSecondary = Color(0xFF6B6B70);

  static const Color transparent = Color(0x00000000);
  static const Color error = Color(0xFFF44336);
  static const Color imageOverlay = Color(0x3DFFFFFF);

  /// Raised surface above [darkSurface]/[lightSurface] (dialogs, sheets,
  /// switch track): the middle step between canvas and content.
  static const Color darkSurfaceRaised = Color(0xFF303135);
  static const Color lightSurfaceRaised = Color(0xFFF7F7F8);

  /// Hairline separators; intentionally fainter than the subdued text tint.
  static const Color darkDivider = Color(0x1FD5D5D5);
  static const Color lightDivider = Color(0x1F383838);

  /// Scrim/overlay tone for dimming content under floating surfaces.
  static const Color surfaceOverlay = Color(0x52000000);

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
