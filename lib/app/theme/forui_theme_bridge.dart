import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../layout/form_factor.dart';
import '../motion/motion_tokens.dart';
import '../system_ui.dart';
import 'func_semantic_tokens.dart';

/// Builds a [FTypeface] locked to [textTheme]'s platform font and fallback
/// chain so Forui widgets never pull in the bundled Inter font (THEME-02).
FTypeface _typefaceFrom(
  TextTheme textTheme,
  Color foreground, {
  required TargetPlatform platform,
  required bool touch,
}) {
  final sample = textTheme.bodyMedium;
  final baseFamily = sample?.fontFamily;
  final fallback = sample?.fontFamilyFallback;
  final resolvedFamily = (baseFamily != null && baseFamily.isNotEmpty)
      ? baseFamily
      : (fallback != null && fallback.isNotEmpty)
      ? fallback.first
      : Typography.material2021(
          platform: platform,
        ).black.bodyMedium!.fontFamily!;
  TextStyle slot(
    double desktopSize,
    double desktopHeight,
    double touchSize,
    double touchHeight,
  ) => TextStyle(
    color: foreground,
    fontFamily: baseFamily,
    fontFamilyFallback: fallback,
    fontSize: touch ? touchSize : desktopSize,
    height: touch ? touchHeight : desktopHeight,
    leadingDistribution: TextLeadingDistribution.even,
  );

  return FTypeface(
    fontFamily: resolvedFamily,
    fontFamilyFallback: fallback,
    xs3: slot(8, 1, 10, 1),
    xs2: slot(10, 1, 12, 1),
    xs: slot(12, 1.25, 14, 1.25),
    sm: slot(14, 1.25, 16, 1.5),
    md: slot(16, 1.5, 18, 1.75),
    lg: slot(18, 1.75, 20, 1.75),
    xl: slot(20, 1.75, 22, 2),
    xl2: slot(22, 2, 30, 2.25),
    xl3: slot(30, 2.25, 36, 2.5),
    xl4: slot(36, 2.5, 48, 1),
    xl5: slot(48, 1, 60, 1),
    xl6: slot(60, 1, 72, 1),
    xl7: slot(72, 1, 96, 1),
    xl8: slot(96, 1, 108, 1),
  );
}

/// One-way bridge mapping Parfait's resolved Material [ThemeData] (and
/// [FuncSemanticTokens]) into a matching [FThemeData].
///
/// Colors read exclusively from `theme.colorScheme` and `FuncSemanticTokens` so
/// dynamic palettes apply cleanly; haptics default to [FHapticFeedback.none] so
/// app wrappers remain the sole [AppHaptics] owners.
FThemeData foruiThemeFrom(
  ThemeData theme, {
  required bool touch,
  Duration? determinateProgressDuration,
}) {
  final scheme = theme.colorScheme;
  final tokens = theme.extension<FuncSemanticTokens>();
  final dark = theme.brightness == Brightness.dark;
  final hairline = tokens?.brandHairline ?? scheme.outlineVariant;
  final canvas = tokens?.canvas ?? theme.scaffoldBackgroundColor;

  final colors = FColors(
    brightness: theme.brightness,
    systemOverlayStyle: funcSystemBarsStyle(theme.brightness),
    barrier: dark ? const Color(0x8A000000) : const Color(0x52000000),
    background: canvas,
    foreground: scheme.onSurface,
    primary: scheme.primary,
    primaryForeground: scheme.onPrimary,
    secondary: scheme.surfaceContainerHigh,
    secondaryForeground: scheme.onSurface,
    muted: scheme.surfaceContainer,
    mutedForeground: scheme.onSurfaceVariant,
    destructive: scheme.error,
    destructiveForeground: scheme.onError,
    error: scheme.error,
    errorForeground: scheme.onError,
    card: scheme.surfaceContainer,
    border: hairline,
    disabledOpacity: 0.48,
  );

  final typeface = _typefaceFrom(
    theme.textTheme,
    scheme.onSurface,
    platform: theme.platform,
    touch: touch,
  );
  final typography = FTypography(display: typeface, body: typeface);
  final style =
      FStyle.inherit(
        colors: colors,
        typography: typography,
        touch: touch,
      ).copyWith(
        borderRadius: const FBorderRadius(
          md: FuncShape.control,
          lg: FuncShape.card,
          xl: FuncShape.dialog,
          pill: FuncShape.pill,
        ),
        borderWidth: 1,
      );
  const noHaptics = FHapticFeedback.none();

  final baseAccordion = FAccordionStyle.inherit(
    colors: colors,
    typography: typography,
    style: style,
    touch: touch,
  );
  final accordionStyle = baseAccordion.copyWith(
    titleTextStyle: FVariants.all(
      (theme.textTheme.titleSmall ?? typography.display.sm).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
    ),
    childTextStyle: TextStyleDelta.value(
      (theme.textTheme.bodySmall ?? typography.body.sm).copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    titlePadding: const EdgeInsetsGeometryDelta.value(
      EdgeInsets.symmetric(vertical: FuncSpacing.sm),
    ),
    childPadding: const EdgeInsetsGeometryDelta.value(
      EdgeInsets.only(bottom: FuncSpacing.md),
    ),
  );

  final baseDialog = FDialogStyle.inherit(
    style: style,
    colors: colors,
    typography: typography,
    hapticFeedback: noHaptics,
    touch: touch,
  );
  final dialogStyle = baseDialog.copyWith(
    decoration: DecorationDelta.value(
      ShapeDecoration(
        color: scheme.surfaceContainerHigh,
        shadows: tokens?.layerLift ?? kElevationToShadow[6],
        shape: RoundedSuperellipseBorder(
          side: BorderSide(color: hairline),
          borderRadius: FuncShape.dialog,
        ),
      ),
    ),
    titleTextStyle: TextStyleDelta.value(
      (theme.textTheme.titleLarge ?? typography.display.md).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    bodyTextStyle: TextStyleDelta.value(
      (theme.textTheme.bodyMedium ?? typography.body.sm).copyWith(
        color: scheme.onSurface,
      ),
    ),
    insetPadding: const EdgeInsetsGeometryDelta.value(
      EdgeInsets.all(FuncSpacing.lg),
    ),
  );

  final baseDeterminate = FDeterminateProgressStyle.inherit(
    colors: colors,
    style: style,
  );
  final determinateProgressStyle = baseDeterminate.copyWith(
    trackDecoration: DecorationDelta.value(
      ShapeDecoration(
        shape: RoundedSuperellipseBorder(borderRadius: style.borderRadius.pill),
        color: hairline,
      ),
    ),
    constraints: const BoxConstraints.tightFor(height: 4.0),
    motion: determinateProgressDuration == null
        ? null
        : FDeterminateProgressMotion(
            duration: determinateProgressDuration,
            curve: MotionTokens.stateFadeCurve,
          ),
  );

  final baseProgress = FProgressStyle.inherit(colors: colors, style: style);
  final progressStyle = baseProgress.copyWith(
    trackDecoration: DecorationDelta.value(
      ShapeDecoration(
        shape: RoundedSuperellipseBorder(borderRadius: style.borderRadius.pill),
        color: hairline,
      ),
    ),
    constraints: const BoxConstraints.tightFor(height: 4.0),
  );

  final switchLabels = FLabelStyles.inherit(style: style);
  final switchStyle = FSwitchStyle(
    focusColor: scheme.primary,
    trackColor: FVariants(
      scheme.surfaceContainerHighest,
      variants: {
        [FSwitchVariantConstraint.disabled]: scheme.surfaceContainerHighest
            .withValues(alpha: 0.12),
        [FSwitchVariantConstraint.selected]: scheme.primary,
        [
          FSwitchVariantConstraint.selected.and(
            FSwitchVariantConstraint.disabled,
          ),
        ]: scheme.onSurface.withValues(
          alpha: 0.12,
        ),
      },
    ),
    thumbColor: FVariants(
      scheme.outline,
      variants: {
        [FSwitchVariantConstraint.disabled]: scheme.onSurface.withValues(
          alpha: 0.38,
        ),
        [FSwitchVariantConstraint.selected]: scheme.onPrimary,
        [
          FSwitchVariantConstraint.selected.and(
            FSwitchVariantConstraint.disabled,
          ),
        ]: scheme.surface,
      },
    ),
    leadingLabelStyle: switchLabels.horizontalLeadingStyle,
    trailingLabelStyle: switchLabels.horizontalTrailingStyle,
  );

  return FThemeData(
    colors: colors,
    typography: typography,
    style: style,
    touch: touch,
    hapticFeedback: noHaptics,
    accordionStyle: accordionStyle,
    dialogStyle: dialogStyle,
    determinateProgressStyle: determinateProgressStyle,
    progressStyle: progressStyle,
    switchStyle: switchStyle,
  );
}

class _ForuiThemeScope extends InheritedWidget {
  const _ForuiThemeScope({required super.child});

  @override
  bool updateShouldNotify(_ForuiThemeScope oldWidget) => false;
}

/// Mounts the derived [FTheme] inside the app/test subtree so Forui widgets
/// track brightness, dynamic colors, form factor and `reduceMotion`.
///
/// Caches the derived [FThemeData] against its inputs so unrelated ancestor
/// rebuilds (e.g., window resizes or non-theme setting writes) never rebuild
/// the full Forui theme or re-trigger `FTheme` transitions.
class ForuiThemeHost extends StatefulWidget {
  const ForuiThemeHost({super.key, required this.child});

  /// Returns [child] directly when already under a [ForuiThemeHost] (prod
  /// `AppChrome` and `localizedApp`), or wraps it in one for standalone widget
  /// tests using a bare `MaterialApp`.
  static Widget ensure(BuildContext context, Widget child) =>
      context.getInheritedWidgetOfExactType<_ForuiThemeScope>() != null
      ? child
      : ForuiThemeHost(child: child);

  final Widget child;

  @override
  State<ForuiThemeHost> createState() => _ForuiThemeHostState();
}

class _ForuiThemeHostState extends State<ForuiThemeHost> {
  ThemeData? _lastTheme;
  bool? _lastTouch;
  Duration? _lastDeterminateDuration;
  FThemeData? _cachedData;

  FThemeData _resolveData(
    ThemeData theme, {
    required bool touch,
    required Duration determinateDuration,
  }) {
    final cached = _cachedData;
    if (cached != null &&
        _lastTheme == theme &&
        _lastTouch == touch &&
        _lastDeterminateDuration == determinateDuration) {
      return cached;
    }
    _lastTheme = theme;
    _lastTouch = touch;
    _lastDeterminateDuration = determinateDuration;
    return _cachedData = foruiThemeFrom(
      theme,
      touch: touch,
      determinateProgressDuration: determinateDuration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touch = FormFactor.of(context) != FormFactor.pc;
    final motionEnabled = MotionTokens.enabled(context);
    final accessibleNavigation =
        MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    final determinateDuration = MotionTokens.resolve(
      context,
      MotionTokens.stateFade,
    );
    return _ForuiThemeScope(
      child: FTheme(
        data: _resolveData(
          theme,
          touch: touch,
          determinateDuration: determinateDuration,
        ),
        accessibility: FAccessibility(
          accessibleNavigation: accessibleNavigation,
          motion: motionEnabled
              ? FAccessibilityMotion.all
              : FAccessibilityMotion.disabled,
          focusHighlight: !touch,
        ),
        motion: FThemeMotion(
          duration: MotionTokens.resolve(context, MotionTokens.themeChange),
          curve: MotionTokens.themeChangeCurve,
        ),
        child: widget.child,
      ),
    );
  }
}
