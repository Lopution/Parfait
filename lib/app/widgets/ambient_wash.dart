import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

/// Ambient light: an image's own colour at the page's lightness (THEME-19).
/// Each pixel's luma becomes the page's (moved by a small lift) and its
/// chroma is scaled, so a dark image does not grey a light page nor a
/// white one fog a dark page, and neutral images sink into the page.
abstract final class AmbientTone {
  /// Where the wash's lightness sits against the page's: a touch below it
  /// on light, above it on dark, so a colour has room to show.
  static const double _lightLift = -0.03;
  static const double _darkLift = 0.07;

  /// How much of the image's colour, its distance from grey, survives.
  /// Saturated colours clip at the gamut edge and lose some of it: a share
  /// that never clips (about 0.04 on light, 0.18 on dark) leaves no colour.
  static const double _lightChroma = 0.4;
  static const double _darkChroma = 0.6;

  static ColorFilter of(ThemeData theme) => ColorFilter.matrix(matrixOf(theme));

  /// The row-major 4×5 matrix [of] applies, on 0–255 channels.
  @visibleForTesting
  static List<double> matrixOf(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final page = theme.colorScheme.surface;
    final lift = dark ? _darkLift : _lightLift;
    final chroma = dark ? _darkChroma : _lightChroma;
    const luma = [0.2126, 0.7152, 0.0722];
    final base = [page.r, page.g, page.b];
    return <double>[
      for (var k = 0; k < 3; k++) ...[
        for (var j = 0; j < 3; j++) chroma * ((k == j ? 1 : 0) - luma[j]),
        0,
        (base[k] + lift) * 255,
      ],
      0, 0, 0, 1, 0, //
    ];
  }
}

/// [image] blurred and tone-locked ([AmbientTone]) over the page colour,
/// filling its box. Opaque, so it also hides what scrolls under it. Fades
/// are the caller's.
class AmbientWash extends StatelessWidget {
  const AmbientWash({super.key, required this.image, this.blur = 28});

  /// Laid out to cover the box.
  final Widget image;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRect(
      child: ColoredBox(
        color: theme.colorScheme.surface,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: blur,
            sigmaY: blur,
            tileMode: TileMode.clamp,
          ),
          child: ColorFiltered(
            colorFilter: AmbientTone.of(theme),
            child: image,
          ),
        ),
      ),
    );
  }
}
