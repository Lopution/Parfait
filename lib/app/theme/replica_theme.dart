import 'package:material_ui/material_ui.dart';

import '../system_ui.dart';
import 'func_semantic_tokens.dart';
import 'func_tokens.dart';

ThemeData replicaTheme(Brightness brightness) {
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

  // fontFamily goes through apply() as well: ThemeData(fontFamily:) only
  // lands on the *default* textTheme before merge(), so base styles that
  // carry an explicit platform family (Roboto on the untouched slots like
  // labelMedium/titleLarge) would otherwise win the merge and leak through.
  final baseTextTheme = ThemeData(brightness: brightness).textTheme.apply(
    bodyColor: text,
    displayColor: text,
    fontFamily: 'Montserrat',
  );

  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: FuncTokens.primary,
        brightness: brightness,
      ).copyWith(
        primary: FuncTokens.primary,
        secondary: textSecondary,
        surface: background,
        surfaceContainerLowest: background,
        surfaceContainerLow: containerLow,
        surfaceContainer: container,
        surfaceContainerHigh: containerHigh,
        surfaceContainerHighest: containerHighest,
        onPrimary: FuncTokens.lightBackground,
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

  final theme = ThemeData(
    brightness: brightness,
    // Latin/digits render in Montserrat; missing glyphs (CJK, emoji) resolve
    // through the engine's system fallback chain.
    fontFamily: 'Montserrat',
    primaryColor: FuncTokens.primary,
    extensions: [FuncSemanticTokens.fromBrightness(brightness)],
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
    textTheme: baseTextTheme.copyWith(
      headlineSmall: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      titleSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      bodyLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      bodyMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: text,
      ),
      labelSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: text,
      ),
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: background,
      foregroundColor: text,
      elevation: 0,
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
      selectedItemColor: FuncTokens.primary,
      unselectedItemColor: textSecondary,
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: background,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: FuncTokens.primary,
      unselectedLabelColor: textSecondary,
      indicatorColor: FuncTokens.primary,
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
              ? colorScheme.primary
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
      selectedIconTheme: IconThemeData(color: colorScheme.primary),
      unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: colorScheme.primaryContainer,
        selectedForegroundColor: colorScheme.onPrimaryContainer,
      ),
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
  final textTheme = theme.textTheme;
  final tabLabelStyle = textTheme.titleSmall!.copyWith(fontSize: 14);
  final bodyText = textTheme.bodyLarge!.copyWith(fontWeight: FontWeight.w400);
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: textTheme.titleMedium!.copyWith(fontSize: 16),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: bodyText.copyWith(color: onInverseSurface),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: bodyText,
      secondaryLabelStyle: bodyText,
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: textTheme.headlineSmall!.copyWith(fontSize: 24),
      contentTextStyle: bodyText,
    ),
    navigationRailTheme: theme.navigationRailTheme.copyWith(
      selectedLabelTextStyle: textTheme.labelMedium!.copyWith(
        color: colorScheme.primary,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium!.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    tabBarTheme: theme.tabBarTheme.copyWith(
      labelStyle: tabLabelStyle,
      unselectedLabelStyle: tabLabelStyle,
    ),
  );
}
