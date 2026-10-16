import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The one look of toolbar controls standing on artwork (R6): bare glyphs,
/// with neither a disc under them nor a scrim darkening the image. A halo
/// traced tight around each glyph keeps it legible over light and dark
/// images alike. Wrap the controls (or the bar holding them); every
/// [IconButton] below takes the glyph colour, every [Icon] the halo.
///
/// The tap target stays [MaterialTapTargetSize.padded]: desktop themes
/// default to `shrinkWrap`, which would shrink the hit area to 40dp and
/// fail the 48×48 touch-target contract.
class ArtworkControls extends StatelessWidget {
  const ArtworkControls({
    super.key,
    required this.child,
    this.glyph,
    this.halo,
  });

  final Widget child;

  /// Defaults to the theme's accent ([ColorScheme.primary]).
  final Color? glyph;

  /// Defaults to the page surface.
  final Color? halo;

  /// A tight copy pushed out in eight directions traces a solid outline;
  /// one soft blur behind it parts the glyph from a busy image. Blurs
  /// alone stayed a faint glow: an accent glyph on a mid-tone banner of
  /// a near hue disappeared.
  static final _halo = [
    for (var i = 0; i < 8; i++)
      (offset: Offset.fromDirection(i * math.pi / 4, 1.0), blur: 0.6),
    (offset: Offset.zero, blur: 3.0),
  ];

  /// The icon theme of controls on artwork, for a bar that themes its
  /// icons itself (an [AppBar]'s `iconTheme`).
  static IconThemeData iconTheme(
    BuildContext context, {
    Color? glyph,
    Color? halo,
  }) {
    final colors = Theme.of(context).colorScheme;
    final haloColor = halo ?? colors.surface;
    return IconThemeData(
      color: glyph ?? colors.primary,
      shadows: [
        for (final layer in _halo)
          Shadow(
            color: haloColor,
            offset: layer.offset,
            blurRadius: layer.blur,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final icons = iconTheme(context, glyph: glyph, halo: halo);
    final color = icons.color!;
    final style = IconButton.styleFrom(
      foregroundColor: color,
      disabledForegroundColor: color.withValues(alpha: 0.38),
      tapTargetSize: MaterialTapTargetSize.padded,
    ).merge(IconButtonTheme.of(context).style);
    return IconButtonTheme(
      data: IconButtonThemeData(style: style),
      child: IconTheme.merge(data: icons, child: child),
    );
  }
}
