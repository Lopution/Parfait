import 'package:material_ui/material_ui.dart';

/// Two side-by-side panes for detail pages on landscape surfaces (see
/// `AppBreakpoints.useTwoPaneDetail`).
///
/// The [secondary] column takes [secondaryFraction] of the width, kept
/// between [secondaryMinWidth] and [secondaryMaxWidth] so text stays
/// readable on a turned phone and does not sprawl on a desktop; [primary]
/// takes the rest after a 1px divider. Each pane is its own scroll region.
class TwoPane extends StatelessWidget {
  const TwoPane({
    super.key,
    required this.primary,
    required this.secondary,
    this.secondaryFraction = 0.38,
    this.secondaryMinWidth = 320,
    this.secondaryMaxWidth = 480,
  }) : assert(
         secondaryFraction > 0 && secondaryFraction < 1,
         'secondaryFraction must stay inside (0, 1)',
       );

  final Widget primary;
  final Widget secondary;
  final double secondaryFraction;
  final double secondaryMinWidth;
  final double secondaryMaxWidth;

  static const double _dividerWidth = 1;

  /// The secondary column's width inside a [width]-wide two-pane layout.
  double secondaryWidthFor(double width) =>
      (width * secondaryFraction).clamp(secondaryMinWidth, secondaryMaxWidth);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: primary),
          const VerticalDivider(thickness: _dividerWidth, width: _dividerWidth),
          SizedBox(
            width: secondaryWidthFor(constraints.maxWidth),
            child: secondary,
          ),
        ],
      ),
    );
  }
}
