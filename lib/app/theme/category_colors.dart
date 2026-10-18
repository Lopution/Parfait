import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

import 'func_tokens.dart';

/// A category's icon colors: the container and the glyph on it.
typedef CategoryTone = ({Color fill, Color ink});

/// The hues (HCT) of the categories of top-level entries, named by color:
/// a page picks one per category, the same one wherever the category
/// shows. Every hue is drawn at the same chroma and tone, so no category
/// outweighs another; only the hue tells them apart. They sit about 50°
/// apart, clear of the default accent's pink. They are not harmonized
/// toward the accent: pulling every hue 15° toward pink merged blue and
/// purple. A system accent leaves them alone; following it, the pink
/// category collided with whichever hue the accent landed on.
abstract final class CategoryHue {
  /// The default accent's: bookmarks.
  static final pink = FuncTokens.primaryHue;
  static const orange = 55.0;
  static const amber = 90.0;
  static const green = 145.0;
  static const teal = 190.0;
  static const blue = 245.0;
  static const purple = 305.0;
}

/// Chroma of every category hue.
const double _chroma = 40;

/// Tones of the container and the glyph: light, then dark.
const _lightFill = 90, _lightInk = 30, _darkFill = 30, _darkInk = 90;

/// The container and glyph of [hue] for the scheme's brightness. The
/// hues are fixed: a system accent recolors actions and selection, not
/// categories.
CategoryTone categoryTone(ColorScheme scheme, double hue) {
  final palette = TonalPalette.of(hue, _chroma);
  final dark = scheme.brightness == Brightness.dark;
  return (
    fill: Color(palette.get(dark ? _darkFill : _lightFill)),
    ink: Color(palette.get(dark ? _darkInk : _lightInk)),
  );
}

/// Entries that are tools, not content: no hue.
CategoryTone neutralCategoryTone(ColorScheme scheme) =>
    (fill: scheme.surfaceContainerHighest, ink: scheme.onSurfaceVariant);
