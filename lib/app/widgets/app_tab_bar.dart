import 'package:material_ui/material_ui.dart';

import '../layout/app_breakpoints.dart';
import '../theme/func_semantic_tokens.dart';
import 'scroll_edge_fade.dart';

/// The single entry point for top-of-page tab rows (D3). Labels always
/// render at the themed size — they are never shrunk to fit. When the
/// widest label fits every equal slot, the row divides the width evenly —
/// on a row at least [AppBreakpoints.medium] wide each slot at most
/// [maxSlotWidth] with the row kept at the start edge; otherwise it
/// scrolls from the start edge, and an edge with more tabs past it fades
/// out (H3). Counts in labels use tabular figures.
class AppTabBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTabBar({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
    this.labelWrapper,
  });

  /// The labels, in tab order.
  final List<String> labels;

  /// Null falls back to the ambient [DefaultTabController] (watchlist).
  final TabController? controller;

  /// Passed through to [TabBar.onTap] unchanged — hosts that re-arm on a
  /// re-tap must not `animateTo` the already-selected index here.
  final ValueChanged<int>? onTap;

  /// Wraps the label of the tab at an index, e.g. in a long-press menu.
  final Widget Function(int index, Widget label)? labelWrapper;

  static const _labelPadding = EdgeInsets.symmetric(horizontal: FuncSpacing.md);

  /// Widest equal slot on a medium or wider row: past it the labels drift
  /// apart. A phone-wide row is always split in full, however few tabs.
  static const double maxSlotWidth = 180;

  /// Merged into the tab bar's own label style, which keeps its colours.
  static const _tabular = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

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
            painter.text = TextSpan(text: label, style: style?.merge(_tabular));
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
        final bar = TabBar(
          controller: controller,
          isScrollable: !fits,
          tabAlignment: fits ? TabAlignment.fill : TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: FuncSpacing.xs),
          labelPadding: _labelPadding,
          onTap: onTap,
          tabs: [
            for (final (index, label) in labels.indexed)
              Tab(child: _label(index, label)),
          ],
        );
        if (!fits) return ScrollEdgeFade(child: bar);
        final width = maxSlotWidth * labels.length;
        if (constraints.maxWidth < AppBreakpoints.medium ||
            constraints.maxWidth <= width) {
          return bar;
        }
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(width: width, child: bar),
        );
      },
    );
  }

  Widget _label(int index, String label) {
    final text = Text(
      label,
      style: _tabular,
      softWrap: false,
      overflow: TextOverflow.fade,
    );
    return labelWrapper?.call(index, text) ?? text;
  }
}
