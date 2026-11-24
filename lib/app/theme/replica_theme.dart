import 'package:material_ui/material_ui.dart';

import '../system_ui.dart';
import 'func_semantic_tokens.dart';
import 'func_tokens.dart';

/// M3's opacities for a disabled control's content and its container.
const _disabledContentAlpha = 0.38;
const _disabledContainerAlpha = 0.12;
const _disabledActionAlpha = 0.48;

/// How high the layers above a page float: menus, dialogs, modal sheets
/// and prompts (THEME-20).
const double _layerElevation = 6;

const _windowsZhFallback = <String>[
  'Segoe UI Variable',
  'Segoe UI',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Yu Gothic UI',
];

const _windowsJaFallback = <String>[
  'Segoe UI Variable',
  'Segoe UI',
  'Yu Gothic UI',
  'Meiryo',
  'Microsoft YaHei UI',
];

const _windowsOtherFallback = <String>[
  'Segoe UI Variable',
  'Segoe UI',
  'Microsoft YaHei UI',
  'Yu Gothic UI',
];

const _linuxZhFallback = <String>[
  'Noto Sans',
  'Ubuntu',
  'Cantarell',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'WenQuanYi Micro Hei',
  'Noto Sans CJK JP',
];

const _linuxJaFallback = <String>[
  'Noto Sans',
  'Ubuntu',
  'Cantarell',
  'Noto Sans CJK JP',
  'Source Han Sans JP',
  'Noto Sans CJK SC',
];

const _linuxOtherFallback = <String>[
  'Noto Sans',
  'Ubuntu',
  'Cantarell',
  'Noto Sans CJK SC',
  'Noto Sans CJK JP',
];

/// Returns the locale-aware system CJK font fallback chain for Windows and
/// Linux without bundling any font assets (THEME-02).
///
/// Android, iOS, and macOS return `null` to preserve their ROM / PingFang /
/// SF Pro platform typography and engine fallback chain.
List<String>? platformFontFamilyFallback(
  TargetPlatform platform, {
  Locale? locale,
}) {
  final language = locale?.languageCode.toLowerCase();
  return switch (platform) {
    TargetPlatform.windows => switch (language) {
      'zh' => _windowsZhFallback,
      'ja' => _windowsJaFallback,
      _ => _windowsOtherFallback,
    },
    TargetPlatform.linux => switch (language) {
      'zh' => _linuxZhFallback,
      'ja' => _linuxJaFallback,
      _ => _linuxOtherFallback,
    },
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.fuchsia => null,
  };
}

/// Builds Parfait's sole light or dark [ThemeData] (THEME-01).
///
/// [fontFamilyFallback] overrides the platform fallback chain when provided
/// (for example in the locale layout test harness). When omitted, Windows and
/// Linux receive [platformFontFamilyFallback] for [locale], while Android,
/// iOS, and macOS stay on `null` and keep the engine's system fallback chain
/// behind the platform font (THEME-02).
///
/// [systemColors] is the platform dynamic color scheme (wallpaper / system
/// accent); when provided, both accent roles and the full M3 surface/container
/// and neutral ladder follow it so wallpaper tinting applies across canvases,
/// bars, cards, and controls. Without it, neutrals stay on Mika's FuncTokens
/// ladder.
///
/// The default accent is split: `colorScheme.primary` paints text, icons
/// and indicators (a deeper rose on the light page, where the brand pink
/// is too light to read; a lighter pink on the dark), and
/// [FuncSemanticTokens.brand] fills, the brand pink under white in both
/// themes. A system palette paints both.
ThemeData replicaTheme(
  Brightness brightness, {
  ColorScheme? systemColors,
  List<String>? fontFamilyFallback,
  Locale? locale,
  TargetPlatform? platform,
}) {
  final baseTheme = ThemeData(brightness: brightness, platform: platform);
  final resolvedPlatform = baseTheme.platform;
  final effectiveFallback =
      fontFamilyFallback ??
      platformFontFamilyFallback(resolvedPlatform, locale: locale);
  final dark = brightness == Brightness.dark;
  final background =
      systemColors?.surface ??
      (dark ? FuncTokens.darkBackground : FuncTokens.lightBackground);
  final containerLowest = systemColors?.surfaceContainerLowest ?? background;
  final containerLow =
      systemColors?.surfaceContainerLow ??
      (dark ? FuncTokens.darkContainerLow : FuncTokens.lightContainerLow);
  final container =
      systemColors?.surfaceContainer ??
      (dark ? FuncTokens.darkContainer : FuncTokens.lightContainer);
  final containerHigh =
      systemColors?.surfaceContainerHigh ??
      (dark ? FuncTokens.darkContainerHigh : FuncTokens.lightContainerHigh);
  final containerHighest =
      systemColors?.surfaceContainerHighest ??
      (dark
          ? FuncTokens.darkContainerHighest
          : FuncTokens.lightContainerHighest);
  final inverseSurface =
      systemColors?.inverseSurface ??
      (dark ? FuncTokens.darkInverseSurface : FuncTokens.lightInverseSurface);
  final onInverseSurface =
      systemColors?.onInverseSurface ??
      (dark
          ? FuncTokens.darkOnInverseSurface
          : FuncTokens.lightOnInverseSurface);
  final text =
      systemColors?.onSurface ??
      (dark ? FuncTokens.darkText : FuncTokens.lightText);
  final subdued =
      systemColors?.outlineVariant ??
      (dark ? FuncTokens.darkSubdued : FuncTokens.lightSubdued);
  final textSecondary =
      systemColors?.onSurfaceVariant ??
      (dark ? FuncTokens.darkTextSecondary : FuncTokens.lightTextSecondary);

  final accent =
      systemColors?.primary ??
      (dark ? FuncTokens.darkAccent : FuncTokens.lightAccent);
  final brand = systemColors?.primary ?? FuncTokens.primary;
  final onBrand = systemColors?.onPrimary ?? FuncTokens.white;

  final baseTextTheme = baseTheme.textTheme.apply(
    bodyColor: text,
    displayColor: text,
  );

  final seeded = ColorScheme.fromSeed(
    seedColor: systemColors?.primary ?? FuncTokens.primary,
    brightness: brightness,
  );
  final colorScheme = seeded.copyWith(
    primary: accent,
    primaryContainer:
        systemColors?.primaryContainer ??
        (dark
            ? FuncTokens.darkPrimaryContainer
            : FuncTokens.lightPrimaryContainer),
    onPrimaryContainer:
        systemColors?.onPrimaryContainer ??
        (dark
            ? FuncTokens.darkOnPrimaryContainer
            : FuncTokens.lightOnPrimaryContainer),
    inversePrimary:
        systemColors?.inversePrimary ??
        (dark ? FuncTokens.darkInversePrimary : FuncTokens.lightInversePrimary),
    surfaceTint: systemColors?.surfaceTint ?? seeded.surfaceTint,
    secondary: systemColors?.secondary ?? textSecondary,
    surface: background,
    surfaceContainerLowest: containerLowest,
    surfaceContainerLow: containerLow,
    surfaceContainer: container,
    surfaceContainerHigh: containerHigh,
    surfaceContainerHighest: containerHighest,
    onPrimary: onBrand,
    secondaryContainer: systemColors?.secondaryContainer ?? containerHighest,
    onSecondary: systemColors?.onSecondary ?? background,
    onSecondaryContainer: systemColors?.onSecondaryContainer ?? text,
    onSurface: text,
    onSurfaceVariant: textSecondary,
    inverseSurface: inverseSurface,
    onInverseSurface: onInverseSurface,
    // Borders/dividers keep the faint subdued alpha; only text uses the
    // readable secondary color.
    outline: systemColors?.outline ?? subdued,
    outlineVariant: subdued,
    error: dark ? FuncTokens.darkError : FuncTokens.lightError,
    onError: dark ? FuncTokens.darkOnError : FuncTokens.white,
    shadow: dark ? FuncTokens.darkShadow : FuncTokens.lightShadow,
  );

  // One type scale feeds both TextTheme roles and the semantic token ramp
  // (FuncSemanticTokens derives its type slots from these roles). Copy from
  // baseTextTheme rather than constructing bare TextStyles so platform font
  // family, baseline, and Typography.localize inheritance stay intact.
  final textTheme = baseTextTheme
      .copyWith(
        headlineSmall: baseTextTheme.headlineSmall?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        titleSmall: baseTextTheme.titleSmall?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: text,
        ),
        bodySmall: baseTextTheme.bodySmall?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: text,
        ),
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        labelSmall: baseTextTheme.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: text,
        ),
      )
      .apply(fontFamilyFallback: effectiveFallback);

  final semanticTokens = FuncSemanticTokens.fromBrightness(
    brightness,
    textTheme,
    brand: brand,
    onBrand: onBrand,
    accent: accent,
    canvas: background,
    surface: container,
    surfaceRaised: containerHigh,
    contentPrimary: text,
    contentSecondary: textSecondary,
    divider: systemColors != null ? text.withValues(alpha: 0.12) : null,
  );

  final theme = ThemeData(
    brightness: brightness,
    platform: resolvedPlatform,
    // Restrained flat state layers replace M3's expanding ripple circle:
    // every InkWell and ListTile gets an immediate tactile surface tint on
    // press, hover and keyboard focus.
    splashFactory: NoSplash.splashFactory,
    splashColor: FuncTokens.transparent,
    highlightColor: colorScheme.onSurface.withValues(alpha: dark ? 0.10 : 0.08),
    hoverColor: colorScheme.onSurface.withValues(alpha: dark ? 0.07 : 0.05),
    focusColor: colorScheme.onSurface.withValues(alpha: 0.10),
    // No bundled font: the platform family renders everything, with
    // locale-aware system CJK fallbacks on Windows/Linux and engine fallbacks
    // elsewhere (THEME-02).
    fontFamilyFallback: effectiveFallback,
    primaryColor: colorScheme.primary,
    extensions: [semanticTokens],
    // The prompt card (PromptHost) takes its surface, shape, elevation and
    // action color from here; placement and motion are the host's.
    snackBarTheme:
        const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          elevation: _layerElevation,
        ).copyWith(
          backgroundColor: inverseSurface,
          actionTextColor: colorScheme.inversePrimary,
          shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
        ),
    scaffoldBackgroundColor: background,
    cardColor: colorScheme.surfaceContainer,
    colorScheme: colorScheme,
    textTheme: textTheme,
    // One search field everywhere (THEME-13): flat, one tier above the page.
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(colorScheme.surfaceContainerHigh),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
      ),
    ),
    appBarTheme: AppBarThemeData(
      // One colour in both states: content scrolled under the bar is marked
      // by AppTopBar's shadow, not by a tint or an elevation shadow (which
      // does not show on the dark page; `topBarShadow` is darker there).
      centerTitle: false,
      backgroundColor: background,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: FuncTokens.transparent,
      iconTheme: IconThemeData(color: text),
      actionsIconTheme: IconThemeData(color: text),
      // Pinned rather than per-frame estimated: every app bar in the app is
      // opaque on the page surface, so the bar icons always invert the page
      // brightness (§6 — this changes no page, it only makes the source
      // single).
      systemOverlayStyle: funcSystemBarsStyle(brightness),
    ),
    iconTheme: IconThemeData(color: text),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: background,
      selectedItemColor: colorScheme.primary,
      unselectedItemColor: textSecondary,
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: background,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: colorScheme.primary,
      unselectedLabelColor: textSecondary,
      indicatorColor: colorScheme.primary,
      dividerColor: FuncTokens.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: background,
      elevation: 0,
      surfaceTintColor: FuncTokens.transparent,
      // No indicator: the selected destination is told by its tint alone.
      iconTheme: _SelectedIconThemeProperty(
        selected: colorScheme.primary,
        unselected: colorScheme.onSurfaceVariant,
      ),
      labelTextStyle: _SelectedLabelStyleProperty(
        selected: colorScheme.primary,
        unselected: colorScheme.onSurfaceVariant,
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: background,
      indicatorColor: colorScheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
    ),
    // One text field look (ST6): outlined, the control radius, label
    // floating into the outline.
    inputDecorationTheme: const InputDecorationThemeData(
      border: OutlineInputBorder(borderRadius: FuncShape.control),
    ),
    cardTheme: CardThemeData(
      color: colorScheme.surfaceContainer,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colorScheme.surfaceContainer,
      selectedColor: colorScheme.primaryContainer,
      checkmarkColor: colorScheme.onPrimaryContainer,
      side: BorderSide(color: colorScheme.outline),
      shape: const RoundedRectangleBorder(borderRadius: FuncShape.badge),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: FuncTokens.transparent,
      elevation: _layerElevation,
      // M3's dialog and sheet defaults cast a transparent shadow.
      shadowColor: colorScheme.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: FuncShape.dialog,
        side: BorderSide(color: semanticTokens.brandHairline),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surfaceContainer,
      modalBackgroundColor: colorScheme.surfaceContainer,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
      modalElevation: _layerElevation,
      shadowColor: colorScheme.shadow,
      showDragHandle: true,
      dragHandleColor: colorScheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: FuncShape.sheet,
        side: BorderSide(color: semanticTokens.brandHairline),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(_layerElevation),
        side: WidgetStatePropertyAll(
          BorderSide(color: semanticTokens.brandHairline),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: FuncShape.card,
        side: BorderSide(color: semanticTokens.brandHairline),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colorScheme.primary,
      linearTrackColor: semanticTokens.brandHairline,
      circularTrackColor: semanticTokens.brandHairline,
      strokeCap: StrokeCap.round,
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: _DisabledColorProperty(
          disabled: colorScheme.onSurface.withValues(
            alpha: _disabledActionAlpha,
          ),
        ),
      ),
    ),
    // A count badge is an indicator in the brand fill, not M3's error red.
    badgeTheme: BadgeThemeData(backgroundColor: brand, textColor: onBrand),
    // Filled buttons are brand fills; disabled, they take M3's disabled
    // colors.
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: _DisabledColorProperty(
          enabled: brand,
          disabled: colorScheme.onSurface.withValues(
            alpha: _disabledContainerAlpha,
          ),
        ),
        foregroundColor: _DisabledColorProperty(
          enabled: onBrand,
          disabled: colorScheme.onSurface.withValues(
            alpha: _disabledContentAlpha,
          ),
        ),
      ),
    ),
  );

  // Component themes whose widgets swap DefaultTextStyle wholesale (AppBar
  // title, SnackBar, Chip labels, Dialog texts, rail labels, tab labels)
  // derive their styles from the *resolved* textTheme below — a TextStyle
  // written directly into a component theme lacks a family and falls back
  // to the platform font for Latin letters and digits. Sizes/weights keep
  // their previous values; only the family (and a color where needed) is
  // carried over.
  final resolvedTextTheme = theme.textTheme;
  final tabLabelStyle = resolvedTextTheme.titleSmall!;
  final bodyText = resolvedTextTheme.bodyLarge!.copyWith(
    fontWeight: FontWeight.w400,
  );
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: resolvedTextTheme.titleMedium!.copyWith(fontSize: 16),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: bodyText.copyWith(color: onInverseSurface),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: bodyText,
      secondaryLabelStyle: bodyText,
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: resolvedTextTheme.titleLarge!.copyWith(
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: bodyText,
    ),
    navigationRailTheme: theme.navigationRailTheme.copyWith(
      selectedLabelTextStyle: resolvedTextTheme.labelMedium!.copyWith(
        color: colorScheme.primary,
      ),
      unselectedLabelTextStyle: resolvedTextTheme.labelMedium!.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    tabBarTheme: theme.tabBarTheme.copyWith(
      labelStyle: tabLabelStyle,
      unselectedLabelStyle: tabLabelStyle,
    ),
  );
}

/// Returns a dark [ThemeData] preserving [context]'s ambient font fallback and
/// platform, or `Theme.of(context)` directly when already dark.
ThemeData darkReplicaThemeOf(BuildContext context) {
  final current = Theme.of(context);
  if (current.brightness == Brightness.dark) return current;
  return replicaTheme(
    Brightness.dark,
    fontFamilyFallback: current.textTheme.bodyMedium?.fontFamilyFallback,
    platform: current.platform,
  );
}

@immutable
final class _SelectedIconThemeProperty
    implements WidgetStateProperty<IconThemeData?> {
  const _SelectedIconThemeProperty({
    required this.selected,
    required this.unselected,
  });

  final Color selected;
  final Color unselected;

  @override
  IconThemeData resolve(Set<WidgetState> states) => IconThemeData(
    color: states.contains(WidgetState.selected) ? selected : unselected,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _SelectedIconThemeProperty &&
          other.selected == selected &&
          other.unselected == unselected;

  @override
  int get hashCode => Object.hash(selected, unselected);
}

@immutable
final class _SelectedLabelStyleProperty
    implements WidgetStateProperty<TextStyle?> {
  const _SelectedLabelStyleProperty({
    required this.selected,
    required this.unselected,
  });

  final Color selected;
  final Color unselected;

  @override
  TextStyle resolve(Set<WidgetState> states) {
    final isSelected = states.contains(WidgetState.selected);
    return TextStyle(
      color: isSelected ? selected : unselected,
      fontSize: 12,
      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _SelectedLabelStyleProperty &&
          other.selected == selected &&
          other.unselected == unselected;

  @override
  int get hashCode => Object.hash(selected, unselected);
}

@immutable
final class _DisabledColorProperty implements WidgetStateProperty<Color?> {
  const _DisabledColorProperty({this.enabled, required this.disabled});

  final Color? enabled;
  final Color disabled;

  @override
  Color? resolve(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled) ? disabled : enabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _DisabledColorProperty &&
          other.enabled == enabled &&
          other.disabled == disabled;

  @override
  int get hashCode => Object.hash(enabled, disabled);
}
