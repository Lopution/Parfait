import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// dynamic_color 2.1.0 still returns the CorePalette type that
// material_color_utilities deprecated; its API has no replacement yet, so
// the one deprecated type stays until dynamic_color moves.
// ignore_for_file: deprecated_member_use

import 'package:material_color_utilities/material_color_utilities.dart'
    show CorePalette;
import 'package:material_ui/material_ui.dart';

/// The platform's colour schemes, or null when it has none (Android below
/// 12, desktops without an accent colour).
final systemColorSchemesProvider = FutureProvider<SystemColorSchemes?>((
  ref,
) async {
  // dynamic_color has no iOS implementation, so its channel throws
  // [MissingPluginException] there; that is "no system colours", not a
  // failure (iOS has no Material You palette).
  CorePalette? palette;
  try {
    palette = await DynamicColorPlugin.getCorePalette();
  } on MissingPluginException {
    palette = null;
  }
  if (palette != null) {
    return SystemColorSchemes(
      light: palette.toColorScheme(),
      dark: palette.toColorScheme(brightness: Brightness.dark),
    );
  }
  Color? accent;
  try {
    accent = await DynamicColorPlugin.getAccentColor();
  } on MissingPluginException {
    accent = null;
  }
  if (accent == null) return null;
  return SystemColorSchemes(
    light: ColorScheme.fromSeed(seedColor: accent),
    dark: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
  );
});

@immutable
class SystemColorSchemes {
  const SystemColorSchemes({required this.light, required this.dark});

  final ColorScheme light;
  final ColorScheme dark;
}
