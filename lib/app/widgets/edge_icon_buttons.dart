import 'package:material_ui/material_ui.dart';

/// Icon buttons at the end of a `ListTile`, moved toward the end edge so the
/// last glyph, not its 48dp target, lines up with the text above and below
/// (LAYOUT-15). The target then reaches [glyphInset] into the tile's end
/// padding. A custom row cannot lend its padding so — a tap outside a
/// parent's bounds is lost — and ends its padding [glyphInset] short of
/// the margin instead.
class EdgeIconButtons extends StatelessWidget {
  const EdgeIconButtons({super.key, required this.children});

  /// How far a 24dp glyph sits inside its 48dp target.
  static const double glyphInset = (kMinInteractiveDimension - 24) / 2;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final end = Directionality.of(context) == TextDirection.ltr ? 1.0 : -1.0;
    return Transform.translate(
      offset: Offset(end * glyphInset, 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
