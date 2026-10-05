import 'package:material_ui/material_ui.dart';

import '../system_ui.dart';
import 'func_semantic_tokens.dart';
import 'func_tokens.dart';

/// [fontFamilyFallback] is for layout tests only: the locale layout
/// harness loads its own Latin and CJK stand-ins and names them here.
/// The app leaves it null and keeps the engine's system fallback chain
/// behind the platform font.
///
/// [systemColors] is the platform accent palette (dynamic color); only the
/// accent roles are taken from it — neutrals stay on FuncTokens so every
/// surface tier keeps the app's ladder.
ThemeData replicaTheme(
  Brightness brightness, {
  ColorScheme? systemColors,
  List<String>? fontFamilyFallback,
}) {
  final dark = brightness == Brightness.dark;
  final background = dark
      ? FuncTokens.darkBackground
      : FuncTokens.lightBackground;
  final containerLow = dark
      ? FuncTokens.darkContainerLow
      : FuncTokens.lightContainerLow;
  final container = dark ? FuncTokens.darkContainer : FuncTokens.lightContainer;
  final containerHigh = dark
      ? FuncTokens.darkContainerHigh
      : FuncTokens.lightContainerHigh;
  final containerHighest = dark
      ? FuncTokens.darkContainerHighest
      : FuncTokens.lightContainerHighest;
  final inverseSurface = dark
      ? FuncTokens.darkInverseSurface
      : FuncTokens.lightInverseSurface;
  final onInverseSurface = dark
      ? FuncTokens.darkOnInverseSurface
      : FuncTokens.lightOnInverseSurface;
  final text = dark ? FuncTokens.darkText : FuncTokens.lightText;
  final subdued = dark ? FuncTokens.darkSubdued : FuncTokens.lightSubdued;
  final textSecondary = dark
      ? FuncTokens.darkTextSecondary
      : FuncTokens.lightTextSecondary;

  final baseTextTheme = ThemeData(
    brightness: brightness,
  ).textTheme.apply(bodyColor: text, displayColor: text);

  final seeded = ColorScheme.fromSeed(
    seedColor: systemColors?.primary ?? FuncTokens.primary,
    brightness: brightness,
  );
  final colorScheme = seeded.copyWith(
    primary: systemColors?.primary ?? FuncTokens.primary,
    primaryContainer: systemColors?.primaryContainer ?? seeded.primaryContainer,
    onPrimaryContainer:
        systemColors?.onPrimaryContainer ?? seeded.onPrimaryContainer,
    inversePrimary: systemColors?.inversePrimary ?? seeded.inversePrimary,
    surfaceTint: systemColors?.surfaceTint ?? seeded.surfaceTint,
    secondary: textSecondary,
    surface: background,
    surfaceContainerLowest: background,
    surfaceContainerLow: containerLow,
    surfaceContainer: container,
    surfaceContainerHigh: containerHigh,
    surfaceContainerHighest: containerHighest,
    onPrimary: systemColors?.onPrimary ?? FuncTokens.lightBackground,
    secondaryContainer: containerHighest,
    onSecondary: background,
    onSecondaryContainer: text,
    onSurface: text,
    onSurfaceVariant: textSecondary,
    inverseSurface: inverseSurface,
    onInverseSurface: onInverseSurface,
    // Borders/dividers keep the faint subdued alpha; only text uses the
    // readable secondary color.
    outline: subdued,
    outlineVariant: subdued,
    error: FuncTokens.error,
    onError: FuncTokens.lightBackground,
  );

  // One type scale feeds both TextTheme roles and the semantic token ramp
  // (FuncSemanticTokens derives its type slots from these roles).
  final textTheme = baseTextTheme
      .copyWith(
        headlineSmall: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        titleSmall: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        bodyLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: text,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: text,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: text,
        ),
      )
      // The slots above are new styles; the fallback has to reach them too.
      .apply(fontFamilyFallback: fontFamilyFallback);

  final theme = ThemeData(
    brightness: brightness,
    // No bundled font: the platform family renders everything, with the
    // engine's system fallback chain covering scripts it lacks.
    fontFamilyFallback: fontFamilyFallback,
    primaryColor: colorScheme.primary,
    extensions: [
      FuncSemanticTokens.fromBrightness(
        brightness,
        textTheme,
        primary: colorScheme.primary,
      ),
    ],
    // Keep app hints floating so their entrance and exit use the same
    // readable fade behavior across copy, saved, and exit messages.
    snackBarTheme:
        const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          elevation: 0,
        ).copyWith(
          backgroundColor: inverseSurface,
          actionTextColor: colorScheme.inversePrimary,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
    scaffoldBackgroundColor: background,
    cardColor: colorScheme.surfaceContainer,
    colorScheme: colorScheme,
    textTheme: textTheme,
    appBarTheme: AppBarThemeData(
      // A plain colour would be used for the scrolled-under state too
      // (AppBar resolves both from the same property), hiding M3's
      // surfaceContainer step. Only the background changes; no shadow.
      backgroundColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.scrolledUnder)
            ? colorScheme.surfaceContainer
            : background,
      ),
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
      indicatorColor: colorScheme.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return TextStyle(
          color: states.contains(WidgetState.selected)
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: background,
      indicatorColor: colorScheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
    ),
    cardTheme: CardThemeData(
      color: colorScheme.surfaceContainer,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colorScheme.surfaceContainer,
      selectedColor: colorScheme.primaryContainer,
      checkmarkColor: colorScheme.onPrimaryContainer,
      side: BorderSide(color: colorScheme.outline),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(28)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surfaceContainer,
      modalBackgroundColor: colorScheme.surfaceContainer,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: colorScheme.onSurfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colorScheme.onPrimary
            : colorScheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colorScheme.primary
            : colorScheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? FuncTokens.transparent
            : colorScheme.outline;
      }),
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
      titleTextStyle: resolvedTextTheme.headlineSmall!.copyWith(fontSize: 24),
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
