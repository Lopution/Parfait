import 'package:flutter/material.dart';
import 'func_tokens.dart';

ThemeData replicaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;

  return ThemeData(
    brightness: brightness,
    useMaterial3: false,
    scaffoldBackgroundColor:
        dark ? FuncTokens.darkBackground : FuncTokens.lightBackground,
    colorScheme: ColorScheme.fromSeed(
      seedColor: FuncTokens.primary,
      brightness: brightness,
    ).copyWith(
      primary: FuncTokens.primary,
      surface: dark ? FuncTokens.darkSurface : FuncTokens.lightSurface,
    ),
  );
}
