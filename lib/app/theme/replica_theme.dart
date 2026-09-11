import 'package:material_ui/material_ui.dart';

import 'func_semantic_tokens.dart';
import 'func_tokens.dart';

ThemeData replicaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark
      ? FuncTokens.darkBackground
      : FuncTokens.lightBackground;
  final surface = dark ? FuncTokens.darkSurface : FuncTokens.lightSurface;
  final surfaceRaised = dark
      ? FuncTokens.darkSurfaceRaised
      : FuncTokens.lightSurfaceRaised;
  final text = dark ? FuncTokens.darkText : FuncTokens.lightText;
  final subdued = dark ? FuncTokens.darkSubdued : FuncTokens.lightSubdued;
  final textSecondary = dark
      ? FuncTokens.darkTextSecondary
      : FuncTokens.lightTextSecondary;

  final baseTextTheme = ThemeData(
    brightness: brightness,
  ).textTheme.apply(bodyColor: text, displayColor: text);

  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: FuncTokens.primary,
        brightness: brightness,
      ).copyWith(
        primary: FuncTokens.primary,
        secondary: FuncTokens.primary,
        surface: surface,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: surfaceRaised,
        surfaceContainerHighest: surfaceRaised,
        onPrimary: FuncTokens.lightBackground,
        onSecondary: textSecondary,
        onSurface: text,
        onSurfaceVariant: textSecondary,
        // Borders/dividers keep the faint subdued alpha; only text uses the
        // readable secondary color.
        outline: subdued,
        outlineVariant: subdued,
        error: FuncTokens.error,
        onError: FuncTokens.lightBackground,
      );

  return ThemeData(
    brightness: brightness,
    primaryColor: FuncTokens.primary,
    extensions: [FuncSemanticTokens.fromBrightness(brightness)],
    // Keep app hints floating so their entrance and exit use the same
    // readable fade behavior across copy, saved, and exit messages.
    snackBarTheme:
        const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          elevation: 0,
        ).copyWith(
          backgroundColor: surface,
          contentTextStyle: TextStyle(color: text),
          actionTextColor: FuncTokens.primary,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
    scaffoldBackgroundColor: background,
    cardColor: surface,
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
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: text,
      ),
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
      labelStyle: TextStyle(color: text),
      secondaryLabelStyle: TextStyle(color: text),
      side: BorderSide(color: colorScheme.outline),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: FuncTokens.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: text,
        fontSize: 24,
        fontWeight: FontWeight.w500,
      ),
      contentTextStyle: TextStyle(color: text, fontSize: 14),
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
}
