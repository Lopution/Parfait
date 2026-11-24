import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/debug/trace_marks.dart';
import '../layout/app_breakpoints.dart';
import '../layout/form_factor.dart';
import '../theme/func_semantic_tokens.dart';
import 'fit_label.dart';
import 'scroll_edge_fade.dart';

/// The single entry point for top-of-page tab rows (D3). Labels always
/// render at the themed size — they are never shrunk to fit. When the
/// widest label fits every equal slot, the row divides the width evenly —
/// on a wide window (where the shell shows its rail, the shell's larger forms) each
/// slot at most [maxSlotWidth], or the widest label if that is wider, with
/// the row kept at the start edge, even on a row narrower than
/// [AppBreakpoints.medium]; a phone always splits its row in full.
/// Otherwise it scrolls from the start edge, and an edge with more tabs
/// past it fades out (H3). Counts in labels use tabular figures.
class AppTabBar extends StatefulWidget implements PreferredSizeWidget {
  const AppTabBar({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
    this.labelWrapper,
    this.maxEqualSlotWidth,
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

  /// Optional override for the wide-row equal slot ceiling (`maxSlotWidth`
  /// when null); longer labels still expand every slot equally (`NAV-14`).
  final double? maxEqualSlotWidth;

  static const _labelPadding = EdgeInsets.symmetric(horizontal: FuncSpacing.md);
  static const _compactScrollableLabelPadding = EdgeInsets.symmetric(
    horizontal: FuncSpacing.sm,
  );
  static const double _compactScrollableBreakpoint = 420;

  /// Widest equal slot on a medium or wider row: past it the labels drift
  /// apart. A longer label widens every slot to its own width, never cut.
  /// A phone-wide row is always split in full, however few tabs.
  static const double maxSlotWidth = 120;

  /// Merged into the tab bar's own label style, which keeps its colours.
  static const _tabular = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Size get preferredSize => TabBar(
    tabs: [for (final label in labels) Tab(text: label)],
  ).preferredSize;

  @override
  State<AppTabBar> createState() => _AppTabBarState();
}

class _AppTabBarState extends State<AppTabBar> {
  final TabBarScrollController _scrollController = TabBarScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.01) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_scrollController.hasClients) _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Resolve label styles exactly the way TabBar does (its titleSmall
    // default merged with the theme's), then the way Text applies the
    // system's text settings, so the fit check measures the same glyphs
    // that will be painted.
    final tabBarTheme = TabBarTheme.of(context);
    final titleSmall = Theme.of(context).textTheme.titleSmall;
    final styles = {
      for (final style in [
        titleSmall?.merge(tabBarTheme.labelStyle),
        titleSmall?.merge(
          tabBarTheme.unselectedLabelStyle ?? tabBarTheme.labelStyle,
        ),
      ])
        LabelFit.paintedStyle(
          context,
          style?.merge(AppTabBar._tabular) ?? AppTabBar._tabular,
        ),
    };
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);

    final row = LayoutBuilder(
      builder: (context, constraints) {
        var widest = 0.0;
        for (final label in widget.labels) {
          for (final style in styles) {
            widest = math.max(
              widest,
              LabelFit.measureLabel(
                label,
                style,
                textScaler,
                textDirection,
                locale: locale,
              ),
            );
          }
        }

        final fits =
            widest + AppTabBar._labelPadding.horizontal <=
            constraints.maxWidth / widget.labels.length;
        final labelPadding =
            !fits &&
                constraints.maxWidth < AppTabBar._compactScrollableBreakpoint
            ? AppTabBar._compactScrollableLabelPadding
            : AppTabBar._labelPadding;
        final bar = TabBar(
          controller: widget.controller,
          scrollController: fits ? null : _scrollController,
          isScrollable: !fits,
          tabAlignment: fits ? TabAlignment.fill : TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: FuncSpacing.xs),
          labelPadding: labelPadding,
          onTap: widget.onTap,
          tabs: [
            for (final (index, label) in widget.labels.indexed)
              Tab(child: _label(index, label)),
          ],
        );
        if (!fits) {
          return Listener(
            onPointerSignal: _handlePointerSignal,
            child: ScrollEdgeFade(initialAfter: true, child: bar),
          );
        }
        // Rounded up: a slot of exactly the measured width can fall a
        // fraction short of the laid-out label and fade its last glyph.
        final slot = math.max(
          widget.maxEqualSlotWidth ?? AppTabBar.maxSlotWidth,
          (widest + AppTabBar._labelPadding.horizontal).ceilToDouble(),
        );
        final width = slot * widget.labels.length;
        final isWide = FormFactor.of(
          context,
        ).hasRail(MediaQuery.sizeOf(context).width);
        if ((!isWide && constraints.maxWidth < AppBreakpoints.medium) ||
            constraints.maxWidth <= width) {
          return bar;
        }
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(width: width, child: bar),
        );
      },
    );
    if (!TraceMarks.enabled) return row;
    return _TabMarks(
      controller: widget.controller,
      labels: widget.labels,
      child: row,
    );
  }

  Widget _label(int index, String label) {
    final text = Text(
      label,
      style: AppTabBar._tabular,
      softWrap: false,
      overflow: TextOverflow.fade,
    );
    return widget.labelWrapper?.call(index, text) ?? text;
  }
}

/// Marks each tab switched to, by tap or swipe, in the system trace
/// (QUAL-05).
class _TabMarks extends StatefulWidget {
  const _TabMarks({
    required this.controller,
    required this.labels,
    required this.child,
  });

  final TabController? controller;
  final List<String> labels;
  final Widget child;

  @override
  State<_TabMarks> createState() => _TabMarksState();
}

class _TabMarksState extends State<_TabMarks> {
  TabController? _controller;
  int? _index;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(_TabMarks oldWidget) {
    super.didUpdateWidget(oldWidget);
    _attach();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    super.dispose();
  }

  void _attach() {
    final controller =
        widget.controller ?? DefaultTabController.maybeOf(context);
    if (controller == _controller) return;
    _controller?.removeListener(_onChanged);
    _controller = controller?..addListener(_onChanged);
    _index = controller?.index;
  }

  void _onChanged() {
    // A switch notifies as it starts and as it settles.
    final index = _controller!.index;
    if (index == _index) return;
    _index = index;
    if (index < widget.labels.length) TraceMarks.tab(widget.labels[index]);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
