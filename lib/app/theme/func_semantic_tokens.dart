import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import 'func_tokens.dart';

/// Fixed spacing scale. Pages must pick from this ladder instead of
/// inventing one-off paddings.
abstract final class FuncSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Named corner radii so cards and controls do not share one radius.
abstract final class FuncShape {
  static const BorderRadius card = BorderRadius.all(Radius.circular(12));
  static const BorderRadius control = BorderRadius.all(Radius.circular(8));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
  static const BorderRadius dialog = BorderRadius.all(Radius.circular(28));
  static const BorderRadius sheet = BorderRadius.vertical(
    top: Radius.circular(28),
  );
}

/// Semantic theme layer. `FuncTokens` stays the owner of raw constants; this
/// extension only *references* them (single literal per value) and exposes
/// intent-named slots so widgets consume meaning rather than palette picks.
@immutable
class FuncSemanticTokens extends ThemeExtension<FuncSemanticTokens> {
  const FuncSemanticTokens({
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceOverlay,
    required this.divider,
    required this.contentPrimary,
    required this.contentSecondary,
    required this.contentTertiary,
    required this.brand,
    required this.onBrand,
    required this.danger,
    required this.success,
    required this.warning,
    required this.display,
    required this.title,
    required this.body,
    required this.label,
    required this.caption,
    required this.numeric,
    required this.motionShort,
    required this.motionStandard,
    required this.motionEmphasized,
  });

  factory FuncSemanticTokens.fromBrightness(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final text = dark ? FuncTokens.darkText : FuncTokens.lightText;
    final textSecondary = dark
        ? FuncTokens.darkTextSecondary
        : FuncTokens.lightTextSecondary;
    return FuncSemanticTokens(
      canvas: dark ? FuncTokens.darkBackground : FuncTokens.lightBackground,
      surface: dark ? FuncTokens.darkSurface : FuncTokens.lightSurface,
      surfaceRaised: dark
          ? FuncTokens.darkSurfaceRaised
          : FuncTokens.lightSurfaceRaised,
      surfaceOverlay: FuncTokens.surfaceOverlay,
      divider: dark ? FuncTokens.darkDivider : FuncTokens.lightDivider,
      contentPrimary: text,
      contentSecondary: textSecondary,
      contentTertiary: dark
          ? FuncTokens.darkText.withValues(alpha: 0.35)
          : FuncTokens.lightText.withValues(alpha: 0.35),
      brand: FuncTokens.primary,
      onBrand: FuncTokens.lightBackground,
      danger: FuncTokens.danger,
      success: FuncTokens.success,
      warning: FuncTokens.warning,
      display: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      title: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text),
      body: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: text),
      label: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: text),
      caption: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: textSecondary,
      ),
      numeric: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: text,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      motionShort: MotionTokens.fast,
      motionStandard: MotionTokens.medium,
      motionEmphasized: MotionTokens.pageTransition,
    );
  }

  // Surface ladder.
  final Color canvas;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceOverlay;
  final Color divider;

  // Content ladder.
  final Color contentPrimary;
  final Color contentSecondary;
  final Color contentTertiary;

  // Brand and status.
  final Color brand;
  final Color onBrand;
  final Color danger;
  final Color success;
  final Color warning;

  // Type ramp.
  final TextStyle display;
  final TextStyle title;
  final TextStyle body;
  final TextStyle label;
  final TextStyle caption;
  final TextStyle numeric;

  // Motion ramp. Gate through [MotionTokens.resolve] so reduced-motion
  // settings collapse them instead of hiding state.
  final Duration motionShort;
  final Duration motionStandard;
  final Duration motionEmphasized;

  /// Reads the ambient extension; falls back to brightness-derived defaults
  /// so shared widgets also render under test harnesses and plugin subtrees
  /// that do not install `replicaTheme`.
  static FuncSemanticTokens of(BuildContext context) {
    return Theme.of(context).extension<FuncSemanticTokens>() ??
        FuncSemanticTokens.fromBrightness(Theme.of(context).brightness);
  }

  @override
  FuncSemanticTokens copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? divider,
    Color? contentPrimary,
    Color? contentSecondary,
    Color? contentTertiary,
    Color? brand,
    Color? onBrand,
    Color? danger,
    Color? success,
    Color? warning,
    TextStyle? display,
    TextStyle? title,
    TextStyle? body,
    TextStyle? label,
    TextStyle? caption,
    TextStyle? numeric,
    Duration? motionShort,
    Duration? motionStandard,
    Duration? motionEmphasized,
  }) {
    return FuncSemanticTokens(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
      divider: divider ?? this.divider,
      contentPrimary: contentPrimary ?? this.contentPrimary,
      contentSecondary: contentSecondary ?? this.contentSecondary,
      contentTertiary: contentTertiary ?? this.contentTertiary,
      brand: brand ?? this.brand,
      onBrand: onBrand ?? this.onBrand,
      danger: danger ?? this.danger,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      display: display ?? this.display,
      title: title ?? this.title,
      body: body ?? this.body,
      label: label ?? this.label,
      caption: caption ?? this.caption,
      numeric: numeric ?? this.numeric,
      motionShort: motionShort ?? this.motionShort,
      motionStandard: motionStandard ?? this.motionStandard,
      motionEmphasized: motionEmphasized ?? this.motionEmphasized,
    );
  }

  @override
  FuncSemanticTokens lerp(FuncSemanticTokens? other, double t) {
    if (other == null) return this;
    Duration lerpDuration(Duration a, Duration b) => Duration(
      microseconds:
          (a.inMicroseconds * (1 - t)).round() + (b.inMicroseconds * t).round(),
    );
    return FuncSemanticTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceOverlay: Color.lerp(surfaceOverlay, other.surfaceOverlay, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      contentPrimary: Color.lerp(contentPrimary, other.contentPrimary, t)!,
      contentSecondary: Color.lerp(
        contentSecondary,
        other.contentSecondary,
        t,
      )!,
      contentTertiary: Color.lerp(contentTertiary, other.contentTertiary, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      onBrand: Color.lerp(onBrand, other.onBrand, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      display: TextStyle.lerp(display, other.display, t)!,
      title: TextStyle.lerp(title, other.title, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      numeric: TextStyle.lerp(numeric, other.numeric, t)!,
      motionShort: lerpDuration(motionShort, other.motionShort),
      motionStandard: lerpDuration(motionStandard, other.motionStandard),
      motionEmphasized: lerpDuration(motionEmphasized, other.motionEmphasized),
    );
  }
}
