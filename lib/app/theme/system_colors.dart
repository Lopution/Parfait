import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// The platform's colour schemes, or null when it has none (Android below
/// 12, desktops without an accent colour).
final systemColorSchemesProvider = FutureProvider<SystemColorSchemes?>((
  ref,
) async {
  final palette = await DynamicColorPlugin.getCorePalette();
  if (palette != null) {
    return SystemColorSchemes(
      light: palette.toColorScheme(),
      dark: palette.toColorScheme(brightness: Brightness.dark),
    );
  }
  final accent = await DynamicColorPlugin.getAccentColor();
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
