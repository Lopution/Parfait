import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../layout/form_factor.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import 'fit_label.dart';
import 'func_bottom_nav.dart';

/// The shell's side rail on larger screens, after Shaft's tablet rail
/// (`HomeNavigationRail`): a header, the destinations from the top, a
/// short rule, then shortcuts to the bookmarks and the downloads that open
/// their pages without taking the selection. The selected destination
/// sits on a light fill of the theme colour; the rail casts the bars'
/// shadow over the content beside it instead of a divider. It scrolls when
/// the window is too short for it.
///
/// Collapsed it is [width] wide, each destination an icon over its label;
/// the header is the app's icon, or on a PC ([FormFactor.pc]) the button
/// that opens it. Open ([expanded], PC only) it is [expandedWidth] wide,
/// each entry an icon beside its label, under the button that closes it
/// and the app's name.
///
/// The destinations read as tabs ("Recommended, tab 1 of 5"), as on the
/// bottom bar; the shortcuts are plain buttons outside that group.
class ShellRail extends StatelessWidget {
  const ShellRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.form,
    required this.expanded,
    required this.onToggle,
    required this.onBookmarks,
    required this.onDownloads,
  });

  final List<FuncBottomNavDestination> destinations;

  /// Null while the page on screen belongs to a destination off the bar.
  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final FormFactor form;
  final bool expanded;

  /// Opens or closes the rail; only a PC's header offers it.
  final VoidCallback onToggle;
  final VoidCallback onBookmarks;
  final VoidCallback onDownloads;

  static const double width = 88;
  static const double expandedWidth = 256;

  static const double _headerHeight = 48;
  static const double _itemWidth = 72;
  static const double _itemMinHeight = 64;
  static const double _rowHeight = 48;
  static const double _ruleWidth = 44;
  static const double _iconSize = 24;
  static const double _itemRadius = 22;

  /// The selected entry's fill: the theme colour at 15%.
  static const double _selectedAlpha = 0.15;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final navTheme = NavigationBarTheme.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: navTheme.backgroundColor ?? colors.surface,
        // The bars' shadow, turned to fall on the content beside the rail.
        boxShadow: [
          for (final shadow in FuncSemanticTokens.of(context).barShadow)
            BoxShadow(
              color: shadow.color,
              offset: Offset(
                rtl ? shadow.offset.dy : -shadow.offset.dy,
                shadow.offset.dx,
              ),
              blurRadius: shadow.blurRadius,
              spreadRadius: shadow.spreadRadius,
            ),
        ],
      ),
      // The content lays out at the panel's width even while the shell
      // animates the rail's width; clip it at the rail's current edge so the
      // part beyond the rail never paints over the page beside it.
      child: ClipRect(
        child: SafeArea(
          left: !rtl,
          right: rtl,
          // The labels stop growing past the bottom bar's 1.3 ceiling.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            // The rail lays its content out at the wider form's width even
            // while the shell animates the rail's width between the two, and
            // the collapsed form keeps to its own column at the start edge.
            // The shell clips the overflow, so the panel slides out from that
            // edge instead of being squeezed into the narrower one.
            child: OverflowBox(
              alignment: AlignmentDirectional.centerStart,
              minWidth: expandedWidth,
              maxWidth: expandedWidth,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: expanded ? FuncSpacing.md : 0,
                        vertical: FuncSpacing.sm,
                      ),
                      // The column and the panel cross-fade while the rail's
                      // width animates; the clip keeps the wider form from
                      // spilling past the still-narrow edge.
                      child: ClipRect(
                        child: AnimatedSwitcher(
                          duration: MotionTokens.resolve(
                            context,
                            MotionTokens.chrome,
                          ),
                          switchInCurve: MotionTokens.chromeCurve,
                          switchOutCurve: MotionTokens.chromeCurve,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: AlignmentDirectional.centerStart,
                            children: [
                              for (final child in previous) child,
                              ?current,
                            ],
                          ),
                          child: KeyedSubtree(
                            key: ValueKey(expanded),
                            child: expanded
                                ? _panel(context)
                                : Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: SizedBox(
                                      width: width,
                                      child: _column(context),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The label style of an entry, selected or not, over the ambient one so
  /// the app's font carries through.
  TextStyle _labelStyle(BuildContext context, {required bool selected}) =>
      DefaultTextStyle.of(context).style.merge(
        NavigationBarTheme.of(
          context,
        ).labelTextStyle?.resolve({if (selected) WidgetState.selected}),
      );

  Color? _iconColor(BuildContext context, {required bool selected}) =>
      NavigationBarTheme.of(
        context,
      ).iconTheme?.resolve({if (selected) WidgetState.selected})?.color;

  Widget _column(BuildContext context) {
    final l10n = context.l10n;
    // One label size for every entry, shrunk until the widest fits.
    final fit = LabelFit.group(
      labels: [
        for (final d in destinations) d.label,
        l10n.railBookmarks,
        l10n.railDownloads,
      ],
      style: LabelFit.paintedStyle(
        context,
        _labelStyle(context, selected: true),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      slotWidth: _itemWidth - 2 * FuncSpacing.xs,
      locale: Localizations.maybeLocaleOf(context),
    );
    Widget item({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) => _RailEntry(
      selected: selected,
      onTap: onTap,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_itemRadius)),
      ),
      child: SizedBox(
        width: _itemWidth,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _itemMinHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: FuncSpacing.sm,
              horizontal: FuncSpacing.xs,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: _iconSize,
                  color: _iconColor(context, selected: selected),
                ),
                const SizedBox(height: FuncSpacing.xs),
                FitLabel(
                  label,
                  fit: fit,
                  style: _labelStyle(context, selected: selected),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      children: [
        SizedBox(
          height: _headerHeight,
          child: Center(
            child: form == FormFactor.pc
                ? IconButton(
                    onPressed: onToggle,
                    tooltip: l10n.railExpand,
                    icon: const Icon(Icons.menu),
                  )
                : const _AppIcon(size: FuncSpacing.xxl),
          ),
        ),
        const SizedBox(height: FuncSpacing.xl),
        _destinations(
          (i, selected) => item(
            icon: destinations[i].icon,
            label: destinations[i].label,
            selected: selected,
            onTap: () => onSelected(i),
          ),
          gap: FuncSpacing.sm,
        ),
        Container(
          width: _ruleWidth,
          height: 1,
          margin: const EdgeInsets.only(
            top: FuncSpacing.xs,
            bottom: FuncSpacing.lg + FuncSpacing.xs,
          ),
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        item(
          icon: Icons.favorite_border,
          label: l10n.railBookmarks,
          selected: false,
          onTap: onBookmarks,
        ),
        const SizedBox(height: FuncSpacing.sm),
        item(
          icon: Icons.downloading_outlined,
          label: l10n.railDownloads,
          selected: false,
          onTap: onDownloads,
        ),
      ],
    );
  }

  Widget _panel(BuildContext context) {
    final l10n = context.l10n;
    final labelSize = Theme.of(context).textTheme.labelLarge?.fontSize;
    Widget row({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) => _RailEntry(
      selected: selected,
      onTap: onTap,
      shape: const StadiumBorder(),
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: FuncSpacing.lg,
            end: FuncSpacing.md,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: _iconSize,
                color: _iconColor(context, selected: selected),
              ),
              const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _labelStyle(
                    context,
                    selected: selected,
                  ).copyWith(fontSize: labelSize),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _headerHeight,
          child: Row(
            children: [
              IconButton(
                onPressed: onToggle,
                tooltip: l10n.railCollapse,
                icon: const Icon(Icons.menu_open),
              ),
              const SizedBox(width: FuncSpacing.xs),
              const _AppIcon(size: FuncSpacing.xl + FuncSpacing.xs),
              const SizedBox(width: FuncSpacing.md),
              Text(
                'Parfait',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        const SizedBox(height: FuncSpacing.xl),
        _destinations(
          (i, selected) => row(
            icon: destinations[i].icon,
            label: destinations[i].label,
            selected: selected,
            onTap: () => onSelected(i),
          ),
          gap: FuncSpacing.xs,
          stretch: true,
        ),
        Divider(
          height: FuncSpacing.xl,
          indent: FuncSpacing.lg,
          endIndent: FuncSpacing.lg,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        row(
          icon: Icons.favorite_border,
          label: l10n.railBookmarks,
          selected: false,
          onTap: onBookmarks,
        ),
        const SizedBox(height: FuncSpacing.xs),
        row(
          icon: Icons.downloading_outlined,
          label: l10n.railDownloads,
          selected: false,
          onTap: onDownloads,
        ),
      ],
    );
  }

  /// The destinations as one tab group, each "label, tab i of n" to a
  /// screen reader, as on the bottom bar.
  Widget _destinations(
    Widget Function(int index, bool selected) entry, {
    required double gap,
    bool stretch = false,
  }) {
    return Semantics(
      role: ui.SemanticsRole.tabBar,
      explicitChildNodes: true,
      container: true,
      child: Column(
        crossAxisAlignment: stretch
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < destinations.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            Builder(
              builder: (context) => MergeSemantics(
                child: Semantics(
                  role: ui.SemanticsRole.tab,
                  selected: i == selectedIndex,
                  child: Stack(
                    children: [
                      entry(i, i == selectedIndex),
                      Semantics(
                        label: MaterialLocalizations.of(context).tabLabel(
                          tabIndex: i + 1,
                          tabCount: destinations.length,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One rail entry: a light fill of the theme colour when [selected], the
/// press and hover ink clipped to [shape].
class _RailEntry extends StatelessWidget {
  const _RailEntry({
    required this.selected,
    required this.onTap,
    required this.shape,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final ShapeBorder shape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: ShellRail._selectedAlpha)
            : Colors.transparent,
        shape: shape,
        child: InkWell(customBorder: shape, onTap: onTap, child: child),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/parfait_icon.png',
    width: size,
    height: size,
    excludeFromSemantics: true,
  );
}
