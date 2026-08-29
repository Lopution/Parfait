import 'package:flutter/material.dart';

import 'func_tokens.dart';

ThemeData replicaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark ? FuncTokens.darkBackground : FuncTokens.lightBackground;
  final surface = dark ? FuncTokens.darkSurface : FuncTokens.lightSurface;
  final text = dark ? FuncTokens.darkText : FuncTokens.lightText;
  final subdued = dark ? FuncTokens.darkSubdued : FuncTokens.lightSubdued;

  final baseTextTheme = ThemeData(brightness: brightness).textTheme.apply(
        bodyColor: text,
        displayColor: text,
      );

  return ThemeData(
    brightness: brightness,
    useMaterial3: false,
    primaryColor: FuncTokens.primary,
    // M2 floating SnackBars go through FadeTransition (fade-in in the
    // 0.4-1.0 interval of the animation); fixed M2 SnackBars only animate
    // height and never fade. Forcing floating gives every hint (copy,
    // saved, exit) a real fade so short-lived hints read as fade in/out
    // instead of a block that pops in and out.
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    scaffoldBackgroundColor: background,
    cardColor: dark ? surface : FuncTokens.lightBackground,
    colorScheme: ColorScheme.fromSeed(
      seedColor: FuncTokens.primary,
      brightness: brightness,
    ).copyWith(
      primary: FuncTokens.primary,
      secondary: FuncTokens.primary,
      surface: surface,
      onPrimary: Colors.white,
      onSecondary: subdued,
      onSurface: text,
      error: Colors.red,
      onError: Colors.white,
    ),
    textTheme: baseTextTheme.copyWith(
      headlineSmall: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: text),
      titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: text),
      titleSmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: text),
      bodyLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: text),
      bodyMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: text),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: text),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: text),
      labelSmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: text),
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: background,
      foregroundColor: text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
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
      unselectedItemColor: dark ? const Color(0xFF8C8C8C) : text,
    ),
    bottomAppBarTheme: BottomAppBarThemeData(
      color: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: FuncTokens.primary,
      unselectedLabelColor: text,
    ),
  );
}
