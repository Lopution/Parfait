import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// The single entry point for top-of-page tab rows (D3). Labels always
/// render at the themed size — they are never shrunk to fit. When the
/// widest label fits every equal slot, the row divides the width evenly;
/// otherwise it scrolls from the start edge.
class AppTabBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTabBar({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
  });

  /// The labels, in tab order.
  final List<String> labels;

  /// Null falls back to the ambient [DefaultTabController] (watchlist).
  final TabController? controller;

  /// Passed through to [TabBar.onTap] unchanged — hosts that re-arm on a
  /// re-tap must not `animateTo` the already-selected index here.
  final ValueChanged<int>? onTap;

  static const _labelPadding = EdgeInsets.symmetric(horizontal: FuncSpacing.md);

  @override
  Size get preferredSize => TabBar(
    tabs: [for (final label in labels) Tab(text: label)],
  ).preferredSize;

  @override
  Widget build(BuildContext context) {
    // Resolve label styles exactly the way TabBar does so the fit check
    // measures the same glyphs that will be painted.
    final tabBarTheme = TabBarTheme.of(context);
    final titleSmall = Theme.of(context).textTheme.titleSmall;
    final styles = <TextStyle?>{
      tabBarTheme.labelStyle ?? titleSmall,
      tabBarTheme.unselectedLabelStyle ?? titleSmall,
    };
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        var widest = 0.0;
        final painter = TextPainter(
          textDirection: textDirection,
          textScaler: textScaler,
        );
        for (final label in labels) {
          for (final style in styles) {
            painter.text = TextSpan(text: label, style: style);
            painter.layout();
            if (painter.width > widest) {
              widest = painter.width;
            }
          }
        }
        painter.dispose();

        final fits =
            widest + _labelPadding.horizontal <=
            constraints.maxWidth / labels.length;
        return TabBar(
          controller: controller,
          isScrollable: !fits,
          tabAlignment: fits ? TabAlignment.fill : TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: 5),
          labelPadding: _labelPadding,
          onTap: onTap,
          tabs: [for (final label in labels) Tab(text: label)],
        );
      },
    );
  }
}
