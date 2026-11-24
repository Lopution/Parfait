import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../icons/app_icons.dart';
import '../icons/ui_icons.dart';
import '../layout/form_factor.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import '../window/desktop_command_bar_scope.dart';
import '../window/desktop_title_bar.dart';
import 'download_count_pill.dart';
import 'fit_label.dart';
import 'func_bottom_nav.dart';

/// The shell's side rail on larger screens: destinations from the top, a short
/// rule, then bookmarks/downloads shortcuts, and (under `DesktopCommandBarScope`)
/// bottom theme/settings controls. Collapsed ([width]) is used on touch tablets
/// until toggled open; expanded ([expandedWidth]) is always used on PCs from
/// 600dp wide and on large touch screens when expanded.
///
/// The destinations read as tabs ("Recommended, tab 1 of 5"), as on the bottom
/// bar; the shortcuts are plain buttons outside that group.
class ShellRail extends StatelessWidget {
  const ShellRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.form,
    required this.expanded,
    required this.onToggle,
    this.onBookmarks,
    this.onDownloads,
    this.onSettings,
    this.bookmarksSelected = false,
    this.downloadsSelected = false,
    this.settingsSelected = false,
    this.onToggleTheme,
    this.themeMode,
    this.isDarkMode,
    this.canToggle,
  });

  final List<FuncBottomNavDestination> destinations;

  /// Null while the page on screen belongs to a destination off the bar.
  final int? selectedIndex;
  final ValueChanged<int> onSelected;
  final FormFactor form;
  final bool expanded;

  /// Opens or closes the rail; shown on large touch layouts.
  final VoidCallback onToggle;
  final VoidCallback? onBookmarks;
  final VoidCallback? onDownloads;
  final VoidCallback? onSettings;
  final bool bookmarksSelected;
  final bool downloadsSelected;
  final bool settingsSelected;
  final VoidCallback? onToggleTheme;
  final ThemeMode? themeMode;
  final bool? isDarkMode;
  final bool? canToggle;

  static const double width = 74;
  static const double expandedWidth = 204;

  static const double _headerHeight = 44;
  static const double _itemWidth = 68;
  static const double _compactHorizontalPadding = FuncSpacing.xxs;
  static const double _itemMinHeight = 52;
  static const double _rowHeight = 42;
  static const double _ruleWidth = 36;
  static const double _iconSize = 20;
  static const double _itemRadius = 10;
  static const double _panelHorizontalPadding =
      FuncSpacing.sm + FuncSpacing.xxs;
  static const double _rowStartPadding = FuncSpacing.md + FuncSpacing.xxs;
  static const double _rowEndPadding = FuncSpacing.md;
  static const double _panelSlotWidth =
      expandedWidth -
      2 * _panelHorizontalPadding -
      _rowStartPadding -
      _rowEndPadding -
      _iconSize -
      FuncSpacing.md;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final navTheme = NavigationBarTheme.of(context);
    final textDirection = Directionality.of(context);
    final rtl = textDirection == TextDirection.rtl;
    final hairline = BorderSide(color: tokens.brandHairline);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: navTheme.backgroundColor ?? colors.surfaceContainerLow,
        border: BorderDirectional(end: hairline),
      ),
      child: ClipRect(
        child: SafeArea(
          left: !rtl,
          right: rtl,
          minimum:
              DesktopChromeMetrics.maybeOf(context)?.topSafePadding ??
              EdgeInsets.zero,
          // The labels stop growing past the bottom bar's 1.3 ceiling.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            // Keep SingleChildScrollView sized to the rail's live width so its
            // scrollbar stays inside the visible 74dp/204dp edge instead of
            // being clipped off at 204dp when collapsed.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final innerMinHeight =
                    (constraints.maxHeight - FuncSpacing.sm * 2).clamp(
                      0.0,
                      double.infinity,
                    );
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: constraints.maxWidth,
                      minHeight: constraints.maxHeight,
                    ),
                    // The column and the panel cross-fade while the rail's
                    // width animates; each form lays out at its natural width
                    // inside [_RailWidthBox] and clips to the moving rail edge.
                    child: ClipRect(
                      child: AnimatedSwitcher(
                        duration: MotionTokens.resolve(
                          context,
                          MotionTokens.chrome,
                        ),
                        switchInCurve: MotionTokens.chromeCurve,
                        switchOutCurve: MotionTokens.chromeCurve,
                        layoutBuilder: (current, previous) => Stack(
                          alignment: AlignmentDirectional.topStart,
                          children: [
                            for (final child in previous) child,
                            ?current,
                          ],
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(expanded),
                          child: expanded
                              ? _RailWidthBox(
                                  width: expandedWidth,
                                  textDirection: textDirection,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: _panelHorizontalPadding,
                                      vertical: FuncSpacing.sm,
                                    ),
                                    child: _panel(
                                      context,
                                      minHeight: innerMinHeight,
                                    ),
                                  ),
                                )
                              : _RailWidthBox(
                                  width: width,
                                  textDirection: textDirection,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: FuncSpacing.sm,
                                    ),
                                    child: _column(
                                      context,
                                      minHeight: innerMinHeight,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                );
              },
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

  TextStyle _compactLabelStyle(BuildContext context, {required bool selected}) {
    final base = _labelStyle(context, selected: selected);
    final compactSize = Theme.of(context).textTheme.labelSmall?.fontSize;
    if (compactSize == null) return base;
    final baseSize = base.fontSize;
    return base.copyWith(
      fontSize: baseSize == null || baseSize > compactSize
          ? compactSize
          : baseSize,
    );
  }

  TextStyle _panelLabelStyle(BuildContext context, {required bool selected}) =>
      _labelStyle(
        context,
        selected: selected,
      ).copyWith(fontSize: Theme.of(context).textTheme.labelLarge?.fontSize);

  Color? _iconColor(BuildContext context, {required bool selected}) =>
      NavigationBarTheme.of(
        context,
      ).iconTheme?.resolve({if (selected) WidgetState.selected})?.color;

  ({IconData icon, String label}) _themeToggleInfo(BuildContext context) {
    final l10n = context.l10n;
    final resolved =
        themeMode ??
        (isDarkMode == null
            ? (Theme.of(context).brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light)
            : (isDarkMode! ? ThemeMode.dark : ThemeMode.light));
    final (icon, modeName) = switch (resolved) {
      ThemeMode.light => (AppIcons.sun, l10n.light),
      ThemeMode.dark => (AppIcons.moon, l10n.dark),
      ThemeMode.system => (UiIcons.devices, l10n.system),
    };
    return (icon: icon, label: l10n.labelValue(l10n.themeSettings, modeName));
  }

  Widget _column(BuildContext context, {required double minHeight}) {
    final l10n = context.l10n;
    final tokens = FuncSemanticTokens.of(context);
    // One label size for every entry, shrunk until the widest fits.
    final fit = LabelFit.group(
      labels: [
        for (final d in destinations) d.label,
        l10n.railBookmarks,
        l10n.railDownloads,
      ],
      style: LabelFit.paintedStyle(
        context,
        _compactLabelStyle(context, selected: true),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      slotWidth: _itemWidth - 2 * _compactHorizontalPadding,
      locale: Localizations.maybeLocaleOf(context),
    );
    Widget item({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      bool downloadBadge = false,
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
              horizontal: _compactHorizontalPadding,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DownloadCountBadgeIcon(
                  enabled: downloadBadge,
                  child: Icon(
                    icon,
                    size: _iconSize,
                    color: _iconColor(context, selected: selected),
                  ),
                ),
                const SizedBox(height: FuncSpacing.xs),
                FitLabel(
                  label,
                  fit: fit,
                  style: _compactLabelStyle(context, selected: selected),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final size = MediaQuery.sizeOf(context);
    final toggleable =
        canToggle ?? form.canToggleRail(size.width, height: size.height);
    final hideHeader = DesktopCommandBarScope.isActiveOf(context);
    final themeInfo = _themeToggleInfo(context);
    final top = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hideHeader)
          const SizedBox(height: FuncSpacing.md)
        else ...[
          SizedBox(
            height: _headerHeight,
            child: Center(
              child: toggleable
                  ? IconButton(
                      onPressed: onToggle,
                      tooltip: l10n.railExpand,
                      icon: const Icon(AppIcons.sidebarExpand),
                    )
                  : _appIcon(FuncSpacing.xxl),
            ),
          ),
          const SizedBox(height: FuncSpacing.xl),
        ],
        _destinations(
          (i, selected) => item(
            icon: selected
                ? (destinations[i].selectedIcon ?? destinations[i].icon)
                : destinations[i].icon,
            label: destinations[i].label,
            selected: selected,
            onTap: () => onSelected(i),
          ),
          gap: FuncSpacing.sm,
        ),
        if (onBookmarks != null || onDownloads != null) ...[
          Container(
            width: _ruleWidth,
            height: 1,
            margin: const EdgeInsets.only(
              top: FuncSpacing.xs,
              bottom: FuncSpacing.lg + FuncSpacing.xs,
            ),
            color: tokens.brandHairline,
          ),
          if (onBookmarks != null)
            item(
              icon: bookmarksSelected ? AppIcons.heartFilled : AppIcons.heart,
              label: l10n.railBookmarks,
              selected: bookmarksSelected,
              onTap: onBookmarks!,
            ),
          if (onDownloads != null) ...[
            const SizedBox(height: FuncSpacing.sm),
            item(
              icon: AppIcons.downloading,
              label: l10n.railDownloads,
              selected: downloadsSelected,
              onTap: onDownloads!,
              downloadBadge: true,
            ),
          ],
        ],
      ],
    );
    if (!hideHeader || (onToggleTheme == null && onSettings == null)) {
      return top;
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          top,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _ruleWidth,
                height: 1,
                margin: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
                color: tokens.brandHairline,
              ),
              if (onToggleTheme != null)
                IconButton(
                  key: const Key('rail-theme-toggle'),
                  tooltip: themeInfo.label,
                  onPressed: onToggleTheme,
                  icon: Icon(themeInfo.icon, size: _iconSize),
                ),
              if (onSettings != null) ...[
                if (onToggleTheme != null)
                  const SizedBox(height: FuncSpacing.xxs),
                IconButton(
                  key: const Key('rail-settings'),
                  isSelected: settingsSelected,
                  tooltip: l10n.settingsTitle,
                  style: settingsSelected
                      ? IconButton.styleFrom(
                          backgroundColor: tokens.brandTint,
                          side: BorderSide(color: tokens.brandTintStroke),
                        )
                      : null,
                  onPressed: onSettings,
                  icon: Icon(
                    settingsSelected
                        ? AppIcons.settingsFilled
                        : AppIcons.settings,
                    size: _iconSize,
                    color: settingsSelected
                        ? _iconColor(context, selected: true)
                        : null,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context, {required double minHeight}) {
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context);
    final toggleable =
        canToggle ?? form.canToggleRail(size.width, height: size.height);
    final hideHeader = DesktopCommandBarScope.isActiveOf(context);
    final themeInfo = _themeToggleInfo(context);
    final style = LabelFit.paintedStyle(
      context,
      _panelLabelStyle(context, selected: true),
    );
    LabelFit fitFor(List<String> labels) => LabelFit.group(
      labels: labels,
      style: style,
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      slotWidth: _panelSlotWidth,
      locale: Localizations.maybeLocaleOf(context),
    );
    final fit = fitFor([
      for (final d in destinations) d.label,
      if (onBookmarks != null) l10n.railBookmarks,
      if (onDownloads != null) l10n.railDownloads,
      if (hideHeader && onSettings != null) l10n.settingsTitle,
    ]);
    final themeFit = hideHeader && onToggleTheme != null
        ? fitFor([
            for (final m in [l10n.light, l10n.dark, l10n.system])
              l10n.labelValue(l10n.themeSettings, m),
          ])
        : fit;
    Widget row({
      Key? key,
      required IconData icon,
      required String label,
      required bool selected,
      bool? selectedSemantics,
      LabelFit? rowFit,
      Widget? trailing,
      required VoidCallback onTap,
    }) => _RailEntry(
      key: key,
      selected: selected,
      selectedSemantics: selectedSemantics,
      onTap: onTap,
      accentBar: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_itemRadius)),
      ),
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: _rowStartPadding,
            end: _rowEndPadding,
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
                child: FitLabel(
                  label,
                  fit: rowFit ?? fit,
                  textAlign: TextAlign.start,
                  style: _panelLabelStyle(context, selected: selected),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
    final top = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hideHeader)
          const SizedBox(height: FuncSpacing.xs)
        else ...[
          SizedBox(
            height: _headerHeight,
            child: Row(
              children: [
                if (toggleable) ...[
                  IconButton(
                    onPressed: onToggle,
                    tooltip: l10n.railCollapse,
                    icon: const Icon(AppIcons.sidebarCollapse),
                  ),
                  const SizedBox(width: FuncSpacing.xs),
                ] else
                  const SizedBox(width: FuncSpacing.sm),
                _appIcon(FuncSpacing.xl + FuncSpacing.xs),
                const SizedBox(width: FuncSpacing.md),
                Expanded(
                  child: Text(
                    'Parfait',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: FuncSpacing.xl),
        ],
        _destinations(
          (i, selected) => row(
            icon: selected
                ? (destinations[i].selectedIcon ?? destinations[i].icon)
                : destinations[i].icon,
            label: destinations[i].label,
            selected: selected,
            onTap: () => onSelected(i),
          ),
          gap: FuncSpacing.xs,
          stretch: true,
        ),
        if (onBookmarks != null || onDownloads != null) ...[
          Divider(
            height: FuncSpacing.xl,
            indent: FuncSpacing.lg,
            endIndent: FuncSpacing.lg,
            color: FuncSemanticTokens.of(context).brandHairline,
          ),
          if (onBookmarks != null)
            row(
              key: const Key('rail-bookmarks'),
              icon: bookmarksSelected ? AppIcons.heartFilled : AppIcons.heart,
              label: l10n.railBookmarks,
              selected: bookmarksSelected,
              selectedSemantics: bookmarksSelected,
              onTap: onBookmarks!,
            ),
          if (onDownloads != null) ...[
            const SizedBox(height: FuncSpacing.xs),
            row(
              key: const Key('rail-downloads'),
              icon: AppIcons.downloading,
              label: l10n.railDownloads,
              selected: downloadsSelected,
              selectedSemantics: downloadsSelected,
              trailing: const DownloadCountPill(),
              onTap: onDownloads!,
            ),
          ],
        ],
      ],
    );
    // When DesktopCommandBarScope is active, show bottom theme/settings controls.
    if (!hideHeader || (onToggleTheme == null && onSettings == null)) {
      return top;
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          top,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(
                height: FuncSpacing.xl,
                indent: FuncSpacing.sm,
                endIndent: FuncSpacing.sm,
                color: FuncSemanticTokens.of(context).brandHairline,
              ),
              if (onToggleTheme != null)
                row(
                  key: const Key('rail-theme-toggle'),
                  icon: themeInfo.icon,
                  label: themeInfo.label,
                  selected: false,
                  rowFit: themeFit,
                  onTap: onToggleTheme!,
                ),
              if (onSettings != null) ...[
                if (onToggleTheme != null)
                  const SizedBox(height: FuncSpacing.xxs),
                row(
                  key: const Key('rail-settings'),
                  icon: settingsSelected
                      ? AppIcons.settingsFilled
                      : AppIcons.settings,
                  label: l10n.settingsTitle,
                  selected: settingsSelected,
                  selectedSemantics: settingsSelected,
                  onTap: onSettings!,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// The destinations as one tab group, each "label, tab i of n" to a
  /// screen reader, as on the bottom bar.
  Widget _destinations(
    Widget Function(int index, bool selected) entry, {
    required double gap,
    bool stretch = false,
  }) {
    final activeIndex =
        (settingsSelected || bookmarksSelected || downloadsSelected)
        ? null
        : selectedIndex;
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
                  selected: i == activeIndex,
                  child: Stack(
                    children: [
                      entry(i, i == activeIndex),
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

/// Lays [child] out at [width] regardless of narrower horizontal constraints
/// while reporting the child's true vertical extent to an enclosing scrollable,
/// aligning the start edge without debug overflow stripes during rail slides.
class _RailWidthBox extends SingleChildRenderObjectWidget {
  const _RailWidthBox({
    required this.width,
    required this.textDirection,
    required super.child,
  });

  final double width;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRailWidthBox(width: width, textDirection: textDirection);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRailWidthBox renderObject,
  ) {
    renderObject
      ..targetWidth = width
      ..textDirection = textDirection;
  }
}

class _RenderRailWidthBox extends RenderAligningShiftedBox {
  _RenderRailWidthBox({
    required double width,
    required TextDirection super.textDirection,
  }) : _targetWidth = width,
       super(alignment: AlignmentDirectional.topStart);

  double _targetWidth;
  double get targetWidth => _targetWidth;
  set targetWidth(double value) {
    if (_targetWidth == value) return;
    _targetWidth = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _targetWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => _targetWidth;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(_targetWidth) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(_targetWidth) ?? 0;

  BoxConstraints _childConstraints(BoxConstraints c) => BoxConstraints(
    minWidth: _targetWidth,
    maxWidth: _targetWidth,
    minHeight: c.minHeight,
    maxHeight: c.maxHeight,
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final currentChild = child;
    if (currentChild == null) return constraints.smallest;
    return constraints.constrain(
      currentChild.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  void performLayout() {
    final currentChild = child;
    if (currentChild == null) {
      size = constraints.smallest;
      return;
    }
    currentChild.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(currentChild.size);
    alignChild();
  }
}

/// One rail entry: a light fill of the theme colour when [selected], the
/// press and hover ink clipped to [shape].
class _RailEntry extends StatelessWidget {
  const _RailEntry({
    super.key,
    required this.selected,
    this.selectedSemantics,
    required this.onTap,
    required this.shape,
    required this.child,
    this.accentBar = false,
  });

  final bool selected;
  final bool? selectedSemantics;
  final VoidCallback onTap;
  final RoundedRectangleBorder shape;
  final Widget child;
  final bool accentBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final selectedBg = accentBar
        ? (theme.brightness == Brightness.dark
              ? colors.surfaceContainerHigh
              : tokens.surface)
        : tokens.brandTint;
    final effectiveShape = shape.copyWith(
      side: selected
          ? BorderSide(
              color: accentBar ? tokens.brandHairline : tokens.brandTintStroke,
            )
          : BorderSide.none,
    );
    return Semantics(
      button: true,
      selected: selectedSemantics,
      child: Material(
        color: selected ? selectedBg : FuncTokens.transparent,
        shape: effectiveShape,
        child: InkWell(
          customBorder: effectiveShape,
          onTap: onTap,
          child: accentBar && selected
              ? Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [
                    child,
                    PositionedDirectional(
                      start: 5,
                      top: 10,
                      bottom: 10,
                      width: 3.5,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: FuncShape.pill,
                        ),
                      ),
                    ),
                  ],
                )
              : child,
        ),
      ),
    );
  }
}

Widget _appIcon(double size) => Image.asset(
  'assets/branding/parfait_icon.png',
  width: size,
  height: size,
  excludeFromSemantics: true,
);
