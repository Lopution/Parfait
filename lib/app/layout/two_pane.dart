import 'package:material_ui/material_ui.dart';

/// Fixed-ratio two-pane container for expanded (≥1200) surfaces.
///
/// The [primary] pane takes [primaryFraction] of the width with a 1px
/// divider before [secondary]; each pane is an independent scroll region.
/// Callers gate usage through `AppBreakpoints.useTwoPaneDetail` so narrow
/// surfaces keep their single-scroll structure untouched.
class TwoPane extends StatelessWidget {
  const TwoPane({
    super.key,
    required this.primary,
    required this.secondary,
    this.primaryFraction = 0.55,
  }) : assert(
         primaryFraction > 0 && primaryFraction < 1,
         'primaryFraction must stay inside (0, 1)',
       );

  final Widget primary;
  final Widget secondary;

  /// Width share of the primary (left) pane; secondary takes the rest.
  final double primaryFraction;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: (primaryFraction * 1000).round(), child: primary),
        const VerticalDivider(thickness: 1, width: 1),
        Expanded(
          flex: ((1 - primaryFraction) * 1000).round(),
          child: secondary,
        ),
      ],
    );
  }
}
