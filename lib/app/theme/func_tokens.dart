import 'package:material_ui/material_ui.dart';

abstract final class FuncTokens {
  /// The brand pink: fills (filled buttons, the follow button) under white
  /// text, and the accent of the dark theme.
  static const Color primary = Color(0xFFFF6289);

  /// The light theme's accent for text, icons and indicators: [primary] is
  /// too light to read on the warm white page.
  static const Color lightAccent = Color(0xFFD61C59);

  static const Color white = Color(0xFFFFFFFF);

  /// The neutrals carry [primary]'s hue at a very low chroma (warm grays);
  /// their lightness, and so every contrast ratio, is the plain grays'.
  static const Color darkBackground = Color(0xFF1A1718);
  static const Color darkText = Color(0xFFD8D4D4);
  static const Color darkSubdued = Color(0xFF655F60);

  /// Secondary *text* must stay readable (the low-alpha subdued colors are
  /// for borders/dividers and were never meant to carry glyphs).
  static const Color darkTextSecondary = Color(0xFFADA7A8);

  static const Color lightBackground = Color(0xFFFFFBFC);
  static const Color lightText = Color(0xFF3B3737);
  static const Color lightSubdued = Color(0x403B3737);
  static const Color lightTextSecondary = Color(0xFF696364);

  static const Color transparent = Color(0x00000000);
  static const Color imageOverlay = Color(0x3DFFFFFF);

  /// Container ladder above the page ([lightBackground]/[darkBackground],
  /// also `surface`/`surfaceContainerLowest`). Each higher step moves away
  /// from the page — darker in light, lighter in dark — so layered surfaces
  /// (cards → dialogs → pickers) stay distinguishable on both themes.
  static const Color lightContainerLow = Color(0xFFFCF8F8);
  static const Color lightContainer = Color(0xFFF7F2F2);
  static const Color lightContainerHigh = Color(0xFFF2EBEC);
  static const Color lightContainerHighest = Color(0xFFEDE5E6);
  static const Color darkContainerLow = Color(0xFF231F1F);
  static const Color darkContainer = Color(0xFF292525);
  static const Color darkContainerHigh = Color(0xFF353030);
  static const Color darkContainerHighest = Color(0xFF40393A);

  /// Inverted surface for transient chrome (SnackBar) so it stands apart
  /// from both the page and the containers on it.
  static const Color lightInverseSurface = Color(0xFF342F30);
  static const Color darkInverseSurface = Color(0xFFE8E3E4);
  static const Color lightOnInverseSurface = lightContainer;
  static const Color darkOnInverseSurface = lightInverseSurface;

  /// Hairline separators; intentionally fainter than the subdued text tint.
  static const Color darkDivider = Color(0x1FD8D4D4);
  static const Color lightDivider = Color(0x1F3B3737);

  /// The shadow a bar at the screen bottom casts up over the content
  /// under it: a tight edge and a short tail, a few dp deep. Darker on the
  /// dark theme, where a faint black disappears into the page.
  static const List<BoxShadow> lightBarShadow = [
    BoxShadow(color: Color(0x1F000000), offset: Offset(0, -1), blurRadius: 2),
    BoxShadow(color: Color(0x0D000000), offset: Offset(0, -1), blurRadius: 5),
  ];
  static const List<BoxShadow> darkBarShadow = [
    BoxShadow(color: Color(0x47000000), offset: Offset(0, -1), blurRadius: 2),
    BoxShadow(color: Color(0x29000000), offset: Offset(0, -1), blurRadius: 5),
  ];

  /// The soft, diffuse shadow of a layer resting above the page (the
  /// detail capsule): a close contact edge and a wide spread. On the
  /// light theme it is the cocoa ink's hue, not black, so it reads warm.
  static const List<BoxShadow> lightLayerLift = [
    BoxShadow(color: Color(0x1A3A2A2E), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x2E3A2A2E), offset: Offset(0, 6), blurRadius: 20),
  ];
  static const List<BoxShadow> darkLayerLift = [
    BoxShadow(color: Color(0x66000000), offset: Offset(0, 1), blurRadius: 3),
    BoxShadow(color: Color(0x8C000000), offset: Offset(0, 8), blurRadius: 24),
  ];

  /// A card that is an object of its own on the page (the detail author
  /// card): a fainter lift than a layer's.
  static const List<BoxShadow> lightCardLift = [
    BoxShadow(color: Color(0x143A2A2E), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x123A2A2E), offset: Offset(0, 3), blurRadius: 10),
  ];
  static const List<BoxShadow> darkCardLift = [
    BoxShadow(color: Color(0x4D000000), offset: Offset(0, 1), blurRadius: 3),
  ];

  /// `colorScheme.shadow`, cast by Material elevation (menus, dialogs,
  /// sheets, prompts): the cocoa ink on light, like [lightLayerLift].
  static const Color lightShadow = Color(0xFF3A2A2E);
  static const Color darkShadow = Color(0xFF000000);

  /// Scrim/overlay tone for dimming content under floating surfaces.
  static const Color surfaceOverlay = Color(0x52000000);

  /// Pills floating over artwork (page counters, load progress):
  /// dark enough that white glyphs keep 4.5:1 even over a pure white image.
  static const Color imageControl = Color(0x8C000000);
  static const Color onImageControl = white;

  /// A bookmarked heart and its burst: a state color, not the accent, so it
  /// stays under system colors and in both themes.
  static const Color bookmarked = Color(0xFFFF4060);

  /// Status tones: M3 tone 40 on the light theme, tone 80 on the dark.
  static const Color lightError = Color(0xFFBB1614);
  static const Color darkError = Color(0xFFFFB4A9);
  static const Color lightWarning = Color(0xFF964900);
  static const Color darkWarning = Color(0xFFFFB786);
  static const Color lightSuccess = Color(0xFF106D20);
  static const Color darkSuccess = Color(0xFF82DB7E);

  static const Color networkProbeDnsWarning = Color(0xFFEF6C00);
  static const Color networkProbeSuccess = Color(0xFF388E3C);
  static const Color networkProbeWarning = Color(0xFFF57C00);
  static const Color networkProbeError = Color(0xFFD32F2F);
  static const Color networkProbeEch = Color(0xFF00796B);
  static const Color networkProbeNoSni = Color(0xFF303F9F);
  static const Color networkProbeNeutral = Color(0xFF616161);
}
