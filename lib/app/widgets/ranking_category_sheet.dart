import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/ranking/ranking_catalog.dart';
import '../../core/ranking/ranking_category.dart';
import '../../core/settings/arrangement.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import '../haptics/app_haptics.dart';
import '../motion/app_overlays.dart';
import '../motion/spring_size.dart';
import '../motion/state_fade.dart';
import '../theme/func_semantic_tokens.dart';
import 'fit_label.dart';
import 'settings/persist_settings.dart';
import '../icons/app_icons.dart';
import '../icons/ui_icons.dart';

/// What a ranking page puts in its category sheet besides the categories.
/// Each row closes the sheet before it acts.
class RankingSheetPage<M extends RankingCategory> {
  const RankingSheetPage({
    required this.tabs,
    required this.onSelect,
    required this.switchLabel,
    required this.switchIcon,
    required this.onSwitch,
    required this.dateLabel,
    required this.onPickDate,
  });

  final ({List<M> modes, M selected}) Function() tabs;
  final ValueChanged<M> onSelect;
  final String switchLabel;
  final IconData switchIcon;
  final VoidCallback onSwitch;
  final String dateLabel;
  final VoidCallback onPickDate;
}

/// Ranking category sheet (issue #85): page actions, category jump grid, and
/// editor (opens straight in editor when [page] is omitted).
Future<void> showRankingCategorySheet<M extends RankingCategory>(
  BuildContext context, {
  required RankingCatalog<M> catalog,
  RankingSheetPage<M>? page,
  bool editing = false,
}) {
  return showAppAdaptiveDialog<void>(
    context: context,
    maxWidth: 640,
    isScrollControlled: true,
    // A long sheet: its top edge stays below the status bar.
    useSafeArea: true,
    builder: (_) => _RankingCategorySheet<M>(
      catalog: catalog,
      page: page,
      editing: editing || page == null,
    ),
  );
}

class _RankingCategorySheet<M extends RankingCategory>
    extends ConsumerStatefulWidget {
  const _RankingCategorySheet({
    required this.catalog,
    required this.page,
    required this.editing,
  });

  final RankingCatalog<M> catalog;
  final RankingSheetPage<M>? page;
  final bool editing;

  @override
  ConsumerState<_RankingCategorySheet<M>> createState() =>
      _RankingCategorySheetState<M>();
}

class _RankingCategorySheetState<M extends RankingCategory>
    extends ConsumerState<_RankingCategorySheet<M>> {
  static const _maxHeightFactor = 0.92;

  late bool _editing = widget.editing;

  /// The arrangement on screen. Each edit shows here first and is saved
  /// at once; a failed save puts the saved one back.
  late Arrangement<M> _draft = ref.read(widget.catalog.arrangementProvider);

  RankingSheetPage<M>? get _page => widget.page;

  Future<void> _save(Arrangement<M> next) async {
    setState(() => _draft = next);
    final saved = await persistSettings(
      context,
      () => widget.catalog.saveArrangement(
        ref.read(settingsProvider.notifier),
        next,
      ),
    );
    if (!saved && mounted) {
      setState(() => _draft = ref.read(widget.catalog.arrangementProvider));
    }
  }

  /// Closes the sheet, then runs [action] from the page.
  void _closeThen(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  void _finishEditing() {
    if (_page == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The page's tabs follow the saved arrangement and the block; rebuild
    // with them.
    ref.watch(widget.catalog.arrangementProvider);
    final block = ref.watch(rankingBlockProvider);
    bool blocked(M mode) =>
        isRankingCategoryBlocked(mode, blockR18: block.r18, blockAI: block.ai);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tokens = FuncSemanticTokens.of(context);
    final page = _page;
    final wide = useWideOverlay(context);
    final pointer = usePointerOverlay(context);
    final footerColor =
        theme.bottomSheetTheme.backgroundColor ??
        (wide
            ? theme.colorScheme.surfaceContainerHigh
            : theme.colorScheme.surfaceContainerLow);
    final showHeaderClose = wide && (pointer || !_editing || page != null);
    final header = Padding(
      // The end meets the grid's edge: a tonal button's edge is its
      // container, a text button's is its label, inset by the padding.
      padding: EdgeInsets.fromLTRB(
        FuncSpacing.xl,
        wide ? FuncSpacing.md : FuncSpacing.lg,
        showHeaderClose
            ? FuncSpacing.sm
            : (_editing ? FuncSpacing.xl : FuncSpacing.md),
        FuncSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _editing ? l10n.rankingMyCategories : l10n.rankingAllCategories,
              style: theme.textTheme.titleLarge,
            ),
          ),
          if (_editing && !pointer)
            FilledButton.tonal(
              onPressed: _finishEditing,
              child: Text(l10n.rankingEditDone),
            )
          else if (!_editing)
            TextButton.icon(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(AppIcons.edit),
              label: Text(l10n.rankingEdit),
            ),
          if (showHeaderClose) ...[
            const SizedBox(width: FuncSpacing.xs),
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(UiIcons.close),
            ),
          ],
        ],
      ),
    );
    final body = _editing
        ? _editor(context, blocked)
        : _browser(context, page!);
    final restoreButton = TextButton.icon(
      onPressed: _draft == widget.catalog.defaults
          ? null
          : () => _save(widget.catalog.defaults),
      icon: const Icon(UiIcons.reset),
      label: Text(l10n.restoreDefault),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.heightOf(context) * _maxHeightFactor,
      ),
      // While editing on a bottom sheet, a vertical drag never moves the
      // sheet: it would fight the long-press drag and could close mid-edit.
      // Wide bounded dialogs have no sheet drag to intercept.
      child: GestureDetector(
        onVerticalDragStart: (_editing && !wide) ? (_) {} : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StateFade(kind: _editing, child: header),
            Flexible(
              child: _SheetBottomScrollFade(
                child: SingleChildScrollView(
                  primary: !(_editing && !wide),
                  padding: const EdgeInsets.only(bottom: FuncSpacing.lg),
                  child: SafeArea(
                    top: false,
                    bottom: !_editing,
                    // Switching between browsing and editing fades the new
                    // view in while the sheet springs to its height.
                    child: SpringSize(
                      child: StateFade(kind: _editing, child: body),
                    ),
                  ),
                ),
              ),
            ),
            if (_editing) ...[
              Divider(height: 1, thickness: 1, color: tokens.brandHairline),
              ColoredBox(
                color: footerColor,
                child: SafeArea(
                  top: false,
                  child: pointer
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FuncSpacing.xl,
                            vertical: FuncSpacing.sm,
                          ),
                          child: OverflowBar(
                            alignment: MainAxisAlignment.end,
                            spacing: FuncSpacing.sm,
                            overflowSpacing: FuncSpacing.sm,
                            overflowAlignment: OverflowBarAlignment.end,
                            children: [
                              restoreButton,
                              FilledButton(
                                onPressed: _finishEditing,
                                child: Text(l10n.rankingEditDone),
                              ),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FuncSpacing.md,
                            vertical: FuncSpacing.xs,
                          ),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: restoreButton,
                          ),
                        ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _browser(BuildContext context, RankingSheetPage<M> page) {
    final l10n = context.l10n;
    final tabs = page.tabs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.xl,
          ),
          leading: Icon(page.switchIcon),
          title: Text(page.switchLabel),
          trailing: const Icon(UiIcons.chevronRight),
          onTap: () => _closeThen(page.onSwitch),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.xl,
          ),
          leading: const Icon(AppIcons.calendar),
          title: Text(l10n.rankingPickDate),
          subtitle: Text(page.dateLabel),
          trailing: const Icon(UiIcons.chevronRight),
          onTap: () => _closeThen(page.onPickDate),
        ),
        _sectionLabel(context, l10n.rankingMyCategories),
        _CategoryGrid<M>(
          modes: tabs.modes,
          labelsToFit: tabs.modes,
          tileBuilder: (mode, size) => _CategoryTile(
            label: _label(context, mode),
            tileWidth: size.width,
            selected: mode == tabs.selected,
            onTap: () => _closeThen(() => page.onSelect(mode)),
          ),
        ),
      ],
    );
  }

  Widget _editor(BuildContext context, bool Function(M) blocked) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final draft = _draft;
    final all = [...draft.shown, ...draft.hidden];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.xl,
            0,
            FuncSpacing.xl,
            FuncSpacing.md,
          ),
          child: Text(
            l10n.rankingDragHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        _CategoryGrid<M>(
          modes: draft.shown,
          labelsToFit: all,
          iconCount: draft.canHide ? 2 : 1,
          tileBuilder: (mode, size) => _ShownTile<M>(
            mode: mode,
            size: size,
            label: _label(context, mode),
            blocked: blocked(mode),
            arrangement: draft,
            onReorder: (next) => setState(() => _draft = next),
            onDragEnd: () => _save(_draft),
            onHide: draft.canHide ? () => _save(draft.hide(mode)) : null,
            onMove: (next) => _save(next),
          ),
        ),
        _sectionLabel(context, l10n.arrangementHidden),
        if (draft.hidden.isEmpty)
          // Fades in as the last hidden category leaves.
          StateFade.onMount(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
              child: Text(
                l10n.rankingHiddenEmpty,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          _CategoryGrid<M>(
            modes: draft.hidden,
            labelsToFit: all,
            iconCount: 1,
            tileBuilder: (mode, size) => _CategoryTile(
              label: _label(context, mode),
              tileWidth: size.width,
              blocked: blocked(mode),
              leadingIcon: UiIcons.add,
              semanticsHint: l10n.rankingShowCategory,
              onTap: () => _save(draft.show(mode)),
            ),
          ),
      ],
    );
  }
}

/// Fades the bottom edge of the category scroll view while more rows remain
/// below the fold, keeping the tree stable so active drags never reparent.
class _SheetBottomScrollFade extends StatefulWidget {
  const _SheetBottomScrollFade({required this.child});

  final Widget child;

  static const _fadeHeight = FuncSpacing.lg;
  static const _edgeSlop = 0.5;

  @override
  State<_SheetBottomScrollFade> createState() => _SheetBottomScrollFadeState();
}

class _SheetBottomScrollFadeState extends State<_SheetBottomScrollFade> {
  var _hasMoreBelow = false;

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final more = metrics.extentAfter > _SheetBottomScrollFade._edgeSlop;
    if (more != _hasMoreBelow && mounted) setState(() => _hasMoreBelow = more);
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (n) => _onMetrics(n.metrics),
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (n) => _onMetrics(n.metrics),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) {
              final stop = bounds.height <= 0
                  ? 0.0
                  : (1.0 - _SheetBottomScrollFade._fadeHeight / bounds.height)
                        .clamp(0.5, 1.0);
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF000000),
                  const Color(0xFF000000),
                  _hasMoreBelow
                      ? const Color(0x00000000)
                      : const Color(0xFF000000),
                ],
                stops: [0.0, stop, 1.0],
              ).createShader(bounds);
            },
            child: widget.child,
          ),
        ),
      );
}

String _label(BuildContext context, RankingCategory mode) =>
    l10nLookup(context.l10n, mode.labelKey);

Widget _sectionLabel(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(
    FuncSpacing.xl,
    FuncSpacing.lg,
    FuncSpacing.xl,
    FuncSpacing.sm,
  ),
  child: Text(
    text,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  ),
);

/// Equal tiles in a [Wrap]: every tile sits under the same parent, so a
/// tile keeps its element (and an active drag) when the order changes.
/// The tile height fits the tallest of [labelsToFit] at the tile width, so
/// no label is cut and rows stay aligned.
class _CategoryGrid<M extends RankingCategory> extends StatelessWidget {
  const _CategoryGrid({
    required this.modes,
    required this.labelsToFit,
    required this.tileBuilder,
    this.iconCount = 0,
  });

  static const _minTileWidth = 96.0;
  static const _spacing = FuncSpacing.sm;

  final List<M> modes;
  final List<M> labelsToFit;
  final Widget Function(M mode, Size size) tileBuilder;
  final int iconCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final labels = [
            for (final mode in labelsToFit) _label(context, mode),
          ];
          // As many columns (capped at 3) as keep the longest name on one line
          // (allowing a gentle single-line fit when a wide modal barely misses
          // 3 columns); two at least, wrapping only what two cannot hold.
          final tileFloor = math.max(
            _minTileWidth,
            _CategoryTile.oneLineWidth(context, labels, iconCount: iconCount),
          );
          var columns = math.min(
            3,
            math.max(2, ((width + _spacing) / (tileFloor + _spacing)).floor()),
          );
          if (columns == 2) {
            final threeColWidth = (width - _spacing * 2) / 3;
            final fitFloor = _CategoryTile.scaledOneLineFloor(
              tileFloor,
              iconCount: iconCount,
            );
            if (threeColWidth >= _minTileWidth && fitFloor <= threeColWidth) {
              columns = 3;
            }
          }
          final tileWidth = (width - _spacing * (columns - 1)) / columns;
          final size = Size(
            tileWidth,
            _CategoryTile.heightFor(
              context,
              tileWidth,
              labels,
              iconCount: iconCount,
            ),
          );
          return Wrap(
            spacing: _spacing,
            runSpacing: _spacing,
            children: [
              for (final mode in modes)
                SizedBox.fromSize(
                  key: ValueKey(mode),
                  size: size,
                  child: tileBuilder(mode, size),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    this.tileWidth,
    this.selected = false,
    this.blocked = false,
    this.leadingIcon,
    this.semanticsHint,
    this.onTap,
  });

  static const _padding = EdgeInsets.symmetric(
    horizontal: FuncSpacing.xs,
    vertical: FuncSpacing.sm,
  );
  static const _iconSize = 16.0;
  static const _shownIconSize = 14.0;
  static const _minHeight = 48.0;
  static const _minSingleLineScale = 0.82;

  final String label;
  final double? tileWidth;
  final bool selected;
  final bool blocked;
  final IconData? leadingIcon;
  final String? semanticsHint;
  final VoidCallback? onTap;

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge;

  static double _iconsWidth(int iconCount) => switch (iconCount) {
    <= 0 => 0.0,
    1 => _iconSize + FuncSpacing.xs,
    _ => iconCount * (_shownIconSize + FuncSpacing.xs),
  };

  /// Width floor under [_minSingleLineScale] so a wide modal only slightly
  /// short of 3 columns fits on one line without shrinking narrow grids.
  static double scaledOneLineFloor(
    double oneLineFloor, {
    required int iconCount,
  }) {
    final fixed = _padding.horizontal + FuncSpacing.xs + _iconsWidth(iconCount);
    if (oneLineFloor <= fixed) return oneLineFloor;
    return (oneLineFloor - fixed) * _minSingleLineScale + fixed;
  }

  /// Gentle single-line [TextScaler] when [label] overflows [tileWidth] by at
  /// most ~12% (preserving one-line layout for `"+ マンガ・ウィークリー"` and
  /// wide 3-column modals), falling back to wrapping on narrow/1.3x sheets.
  static TextScaler _fitScaler(
    BuildContext context, {
    required String label,
    required TextStyle style,
    required double tileWidth,
    required int iconCount,
  }) {
    final base = MediaQuery.textScalerOf(context);
    final available = math.max(
      0.0,
      tileWidth - _padding.horizontal - _iconsWidth(iconCount),
    );
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: base,
      textAlign: TextAlign.center,
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final textWidth = painter.width;
    painter.dispose();
    if (textWidth <= available || textWidth <= 0 || available <= 0) return base;
    final factor = (available - 1.0) / textWidth;
    if (factor < _minSingleLineScale) return base;
    return LabelFit(scale: factor, truncates: false).scaler(base);
  }

  /// The tile width that holds the longest of [labels] on one line, beside
  /// [iconCount] icons.
  static double oneLineWidth(
    BuildContext context,
    List<String> labels, {
    required int iconCount,
  }) {
    final style = LabelFit.paintedStyle(
      context,
      _style(context) ?? const TextStyle(),
    );
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: TextAlign.center,
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );
    var widest = 0.0;
    for (final label in labels) {
      painter.text = TextSpan(text: label, style: style);
      painter.layout();
      widest = math.max(widest, painter.width);
    }
    painter.dispose();
    return widest.ceilToDouble() +
        _iconsWidth(iconCount) +
        _padding.horizontal +
        FuncSpacing.xs;
  }

  /// The height every tile takes: the tallest label wrapped at [tileWidth]
  /// reserving [iconCount] icons so multi-line Japanese/Russian or 1.3x labels
  /// never clip at the bottom.
  static double heightFor(
    BuildContext context,
    double tileWidth,
    List<String> labels, {
    required int iconCount,
  }) {
    final style = LabelFit.paintedStyle(
      context,
      _style(context) ?? const TextStyle(),
    );
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textAlign: TextAlign.center,
      locale: Localizations.maybeLocaleOf(context),
    );
    final maxWidth = math.max(
      1.0,
      tileWidth - _padding.horizontal - _iconsWidth(iconCount),
    );
    var tallest = 0.0;
    for (final label in labels) {
      painter.textScaler = _fitScaler(
        context,
        label: label,
        style: style,
        tileWidth: tileWidth,
        iconCount: iconCount,
      );
      painter.text = TextSpan(text: label, style: style);
      painter.layout(maxWidth: maxWidth);
      tallest = math.max(tallest, painter.height);
    }
    painter.dispose();
    return math.max(
      _minHeight,
      tallest.ceilToDouble() + _padding.vertical + FuncSpacing.xxs,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = blocked
        ? scheme.onSurface.withValues(alpha: 0.38)
        : selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final icon = leadingIcon;
    final rawStyle = _style(context);
    final scaler = tileWidth == null
        ? MediaQuery.textScalerOf(context)
        : _fitScaler(
            context,
            label: label,
            style: LabelFit.paintedStyle(
              context,
              rawStyle ?? const TextStyle(),
            ),
            tileWidth: tileWidth!,
            iconCount: icon != null ? 1 : 0,
          );
    return Semantics(
      selected: selected,
      onTapHint: semanticsHint,
      hint: blocked ? context.l10n.rankingBlocked : null,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: FuncShape.control,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: _padding,
            // The icon runs inline, so a wrapped name keeps it beside its
            // first line.
            child: Center(
              child: Text.rich(
                TextSpan(
                  children: [
                    if (icon != null)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(
                            end: FuncSpacing.xs,
                          ),
                          child: Icon(icon, size: _iconSize, color: foreground),
                        ),
                      ),
                    TextSpan(text: label),
                  ],
                ),
                textAlign: TextAlign.center,
                textScaler: scaler,
                style: rawStyle?.copyWith(color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown category tile: explicit leading handle drags immediately, trailing ×
/// hides without accidental tile-tap hides, screen readers keep move actions.
class _ShownTile<M extends RankingCategory> extends StatelessWidget {
  const _ShownTile({
    required this.mode,
    required this.size,
    required this.label,
    required this.blocked,
    required this.arrangement,
    required this.onReorder,
    required this.onDragEnd,
    required this.onHide,
    required this.onMove,
  });

  final M mode;
  final Size size;
  final String label;
  final bool blocked;
  final Arrangement<M> arrangement;
  final ValueChanged<Arrangement<M>> onReorder;
  final VoidCallback onDragEnd;
  final VoidCallback? onHide;
  final ValueChanged<Arrangement<M>> onMove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final foreground = blocked
        ? scheme.onSurface.withValues(alpha: 0.38)
        : scheme.onSurface;
    final index = arrangement.shown.indexOf(mode);
    final last = arrangement.shown.length - 1;
    final rawStyle = _CategoryTile._style(context);
    final scaler = _CategoryTile._fitScaler(
      context,
      label: label,
      style: LabelFit.paintedStyle(context, rawStyle ?? const TextStyle()),
      tileWidth: size.width,
      iconCount: onHide != null ? 2 : 1,
    );
    final grip = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.xxs,
        vertical: FuncSpacing.xs,
      ),
      child: Icon(
        UiIcons.dragHandle,
        size: _CategoryTile._shownIconSize,
        color: foreground,
      ),
    );
    final handle = Draggable<M>(
      data: mode,
      onDragStarted: AppHaptics.select,
      onDragEnd: (_) => onDragEnd(),
      feedback: Material(
        elevation: 3,
        borderRadius: FuncShape.control,
        child: SizedBox.fromSize(
          size: size,
          child: _CategoryTile(
            label: label,
            tileWidth: size.width,
            blocked: blocked,
            leadingIcon: UiIcons.dragHandle,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: grip),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: grip),
    );
    return DragTarget<M>(
      onWillAcceptWithDetails: (details) {
        final from = arrangement.shown.indexOf(details.data);
        if (from < 0 || details.data == mode) return false;
        onReorder(arrangement.reorder(from, index));
        return false;
      },
      builder: (context, _, _) => Semantics(
        hint: blocked ? l10n.rankingBlocked : null,
        customSemanticsActions: {
          if (index > 0)
            CustomSemanticsAction(label: l10n.rankingMoveEarlier): () =>
                onMove(arrangement.reorder(index, index - 1)),
          if (index < last)
            CustomSemanticsAction(label: l10n.rankingMoveLater): () =>
                onMove(arrangement.reorder(index, index + 1)),
        },
        child: Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: FuncShape.control,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.xxs,
              vertical: FuncSpacing.sm,
            ),
            child: Row(
              children: [
                handle,
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    textScaler: scaler,
                    style: rawStyle?.copyWith(color: foreground),
                  ),
                ),
                if (onHide != null)
                  Semantics(
                    button: true,
                    label: l10n.rankingHideCategory,
                    child: InkWell(
                      borderRadius: FuncShape.pill,
                      onTap: onHide,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.xxs,
                          vertical: FuncSpacing.xs,
                        ),
                        child: Icon(
                          UiIcons.close,
                          size: _CategoryTile._shownIconSize,
                          color: foreground,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
