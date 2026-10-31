import 'package:material_ui/material_ui.dart';

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

  /// Corner badges over artwork (R-18, page count, AI).
  static const BorderRadius badge = BorderRadius.all(Radius.circular(4));
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
    required this.barShadow,
    required this.layerLift,
    required this.cardLift,
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
    required this.workTitle,
  });

  factory FuncSemanticTokens.fromBrightness(
    Brightness brightness,
    TextTheme textTheme, {
    required Color brand,
    required Color onBrand,
  }) {
    final dark = brightness == Brightness.dark;
    final text = dark ? FuncTokens.darkText : FuncTokens.lightText;
    final textSecondary = dark
        ? FuncTokens.darkTextSecondary
        : FuncTokens.lightTextSecondary;
    return FuncSemanticTokens(
      canvas: dark ? FuncTokens.darkBackground : FuncTokens.lightBackground,
      surface: dark ? FuncTokens.darkContainer : FuncTokens.lightContainer,
      surfaceRaised: dark
          ? FuncTokens.darkContainerHigh
          : FuncTokens.lightContainerHigh,
      surfaceOverlay: FuncTokens.surfaceOverlay,
      divider: dark ? FuncTokens.darkDivider : FuncTokens.lightDivider,
      barShadow: dark ? FuncTokens.darkBarShadow : FuncTokens.lightBarShadow,
      layerLift: dark ? FuncTokens.darkLayerLift : FuncTokens.lightLayerLift,
      cardLift: dark ? FuncTokens.darkCardLift : FuncTokens.lightCardLift,
      contentPrimary: text,
      contentSecondary: textSecondary,
      contentTertiary: dark
          ? FuncTokens.darkText.withValues(alpha: 0.35)
          : FuncTokens.lightText.withValues(alpha: 0.35),
      brand: brand,
      onBrand: onBrand,
      danger: dark ? FuncTokens.darkError : FuncTokens.lightError,
      success: dark ? FuncTokens.darkSuccess : FuncTokens.lightSuccess,
      warning: dark ? FuncTokens.darkWarning : FuncTokens.lightWarning,
      // The type ramp derives from the resolved TextTheme so font size and
      // weight have a single source of truth; only colors and tabular
      // figures are applied on top.
      display: textTheme.titleLarge!.copyWith(color: text),
      title: textTheme.titleMedium!.copyWith(color: text),
      body: textTheme.bodyMedium!.copyWith(color: text),
      label: textTheme.labelLarge!.copyWith(color: text),
      caption: textTheme.bodySmall!.copyWith(color: textSecondary),
      numeric: textTheme.labelLarge!.copyWith(
        color: text,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      // No ramp role sits above titleLarge (headlineSmall is 18 here): a
      // work's name plate takes its own step over every section title, as
      // the large app bar title does.
      workTitle: textTheme.titleLarge!.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.25,
        color: text,
      ),
    );
  }

  // Surface ladder.
  final Color canvas;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceOverlay;
  final Color divider;

  /// Cast up by a bar at the screen bottom over the content under it.
  final List<BoxShadow> barShadow;

  /// [barShadow] mirrored: cast down by a bar at the screen top.
  List<BoxShadow> get topBarShadow => [
    for (final shadow in barShadow)
      BoxShadow(
        color: shadow.color,
        offset: Offset(shadow.offset.dx, -shadow.offset.dy),
        blurRadius: shadow.blurRadius,
        spreadRadius: shadow.spreadRadius,
      ),
  ];

  /// Cast by a layer resting above the page (the detail capsule).
  final List<BoxShadow> layerLift;

  /// Cast by a card that is an object of its own on the page.
  final List<BoxShadow> cardLift;

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

  /// A work's title on its detail page.
  final TextStyle workTitle;

  /// Reads the ambient extension; falls back to brightness-derived defaults
  /// so shared widgets also render under test harnesses and plugin subtrees
  /// that do not install `replicaTheme`.
  static FuncSemanticTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<FuncSemanticTokens>() ??
        FuncSemanticTokens.fromBrightness(
          theme.brightness,
          theme.textTheme,
          brand: theme.colorScheme.primary,
          onBrand: theme.colorScheme.onPrimary,
        );
  }

  @override
  FuncSemanticTokens copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? divider,
    List<BoxShadow>? barShadow,
    List<BoxShadow>? layerLift,
    List<BoxShadow>? cardLift,
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
    TextStyle? workTitle,
  }) {
    return FuncSemanticTokens(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
      divider: divider ?? this.divider,
      barShadow: barShadow ?? this.barShadow,
      layerLift: layerLift ?? this.layerLift,
      cardLift: cardLift ?? this.cardLift,
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
      workTitle: workTitle ?? this.workTitle,
    );
  }

  @override
  FuncSemanticTokens lerp(FuncSemanticTokens? other, double t) {
    if (other == null) return this;
    return FuncSemanticTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceOverlay: Color.lerp(surfaceOverlay, other.surfaceOverlay, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      barShadow: BoxShadow.lerpList(barShadow, other.barShadow, t)!,
      layerLift: BoxShadow.lerpList(layerLift, other.layerLift, t)!,
      cardLift: BoxShadow.lerpList(cardLift, other.cardLift, t)!,
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
      workTitle: TextStyle.lerp(workTitle, other.workTitle, t)!,
    );
  }
}

/// Digits of equal width, so a changing number does not shift its
/// neighbours (counts, page numbers, progress).
extension TabularFigures on TextStyle {
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}
