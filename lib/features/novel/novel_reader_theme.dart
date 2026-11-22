import 'package:material_ui/material_ui.dart';

import '../../app/theme/func_semantic_tokens.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/theme/replica_theme.dart';
import '../../core/novel/reader_settings.dart';

/// Builds a palette-matched [ThemeData] for the novel reader stage so reader
/// surfaces (`paper`, `sepia`, `night`) never inherit opposite-brightness
/// foregrounds, buttons, links, or semantic tokens from the outer app theme.
ThemeData novelReaderThemeData(
  ThemeData base,
  NovelReaderPalette palette, {
  required double hintAlpha,
}) {
  final brightness = palette.brightness;
  if (brightness == null) return base;
  final dark = brightness == Brightness.dark;
  final background =
      palette.background ??
      (dark ? FuncTokens.darkBackground : FuncTokens.lightBackground);
  final foreground =
      palette.foreground ?? (dark ? FuncTokens.darkText : FuncTokens.lightText);
  final secondary = foreground.withValues(alpha: hintAlpha);
  final matched = replicaTheme(
    brightness,
    fontFamilyFallback: base.textTheme.bodyMedium?.fontFamilyFallback,
  );
  final scheme = matched.colorScheme.copyWith(
    surface: background,
    onSurface: foreground,
    onSurfaceVariant: secondary,
  );
  final textTheme = matched.textTheme.apply(
    bodyColor: foreground,
    displayColor: foreground,
  );
  final semantic = FuncSemanticTokens.fromBrightness(
    brightness,
    textTheme,
    brand: scheme.primary,
    onBrand: scheme.onPrimary,
    canvas: background,
    surface: background,
    contentPrimary: foreground,
    contentSecondary: secondary,
  );
  final extensions = Map<Object, ThemeExtension<dynamic>>.of(matched.extensions)
    ..[FuncSemanticTokens] = semantic;
  return matched.copyWith(
    platform: base.platform,
    visualDensity: base.visualDensity,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    textTheme: textTheme,
    iconTheme: matched.iconTheme.copyWith(color: foreground),
    extensions: extensions.values,
  );
}
