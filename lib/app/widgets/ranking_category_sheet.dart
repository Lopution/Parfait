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
import '../theme/func_semantic_tokens.dart';
import 'settings/persist_settings.dart';

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

  /// The page's tabs and the selected one, read on every build: an edit in
  /// the sheet changes both.
  final ({List<M> modes, M selected}) Function() tabs;
  final ValueChanged<M> onSelect;

  /// The row to the other kind of ranking.
  final String switchLabel;
  final IconData switchIcon;
  final VoidCallback onSwitch;

  /// "Latest" or the ranking day on screen.
  final String dateLabel;
  final VoidCallback onPickDate;
}

/// The ranking category sheet (issue #85): the page's rows, the categories
/// to jump to, and the editor that orders, hides and shows them. Without a
/// [page] (the settings entry) it opens straight into the editor.
Future<void> showRankingCategorySheet<M extends RankingCategory>(
  BuildContext context, {
  required RankingCatalog<M> catalog,
  RankingSheetPage<M>? page,
  bool editing = false,
}) {
  return showAppBottomSheet<void>(
    context: context,
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
  static const _maxHeightFactor = 0.9;

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
    final page = _page;
    final header = Padding(
      // The end meets the grid's edge: a tonal button's edge is its
      // container, a text button's is its label, inset by the padding.
      padding: EdgeInsets.fromLTRB(
        FuncSpacing.xl,
        FuncSpacing.lg,
        _editing ? FuncSpacing.xl : FuncSpacing.md,
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
          if (_editing)
            FilledButton.tonal(
              onPressed: _finishEditing,
              child: Text(l10n.rankingEditDone),
            )
          else
            TextButton.icon(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.rankingEdit),
            ),
        ],
      ),
    );
    final body = _editing
        ? _editor(context, blocked)
        : _browser(context, page!);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.heightOf(context) * _maxHeightFactor,
      ),
      // While editing, a vertical drag never moves the sheet: it would
      // fight the long-press drag and could close the sheet mid-edit.
      child: GestureDetector(
        onVerticalDragStart: _editing ? (_) {} : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: FuncSpacing.lg),
                child: SafeArea(top: false, child: body),
              ),
            ),
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
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _closeThen(page.onSwitch),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.xl,
          ),
          leading: const Icon(Icons.calendar_month_outlined),
          title: Text(l10n.rankingPickDate),
          subtitle: Text(page.dateLabel),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _closeThen(page.onPickDate),
        ),
        _SectionLabel(l10n.rankingMyCategories),
        _CategoryGrid<M>(
          modes: tabs.modes,
          labelsToFit: tabs.modes,
          tileBuilder: (mode, _) => _CategoryTile(
            label: _label(context, mode),
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
    final anyBlocked = draft.shown.any(blocked);
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
        if (anyBlocked)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.xl,
              FuncSpacing.sm,
              FuncSpacing.xl,
              0,
            ),
            child: Text(
              l10n.rankingBlockedNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        _SectionLabel(l10n.arrangementHidden),
        if (draft.hidden.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
            child: Text(
              l10n.rankingHiddenEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          _CategoryGrid<M>(
            modes: draft.hidden,
            labelsToFit: all,
            tileBuilder: (mode, _) => _CategoryTile(
              label: _label(context, mode),
              blocked: blocked(mode),
              leadingIcon: Icons.add,
              semanticsHint: l10n.rankingShowCategory,
              onTap: () => _save(draft.show(mode)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.md,
            FuncSpacing.md,
            FuncSpacing.md,
            0,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: draft == widget.catalog.defaults
                  ? null
                  : () => _save(widget.catalog.defaults),
              icon: const Icon(Icons.restart_alt),
              label: Text(l10n.restoreDefault),
            ),
          ),
        ),
      ],
    );
  }
}

String _label(BuildContext context, RankingCategory mode) =>
    l10nLookup(context.l10n, mode.labelKey);

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.xl,
        FuncSpacing.lg,
        FuncSpacing.xl,
        FuncSpacing.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Equal tiles in a [Wrap]: every tile sits under the same parent, so a
/// tile keeps its element (and an active drag) when the order changes.
/// The tile height fits the tallest of [labelsToFit] at the tile width, so
/// no label is cut and rows stay aligned.
class _CategoryGrid<M extends RankingCategory> extends StatelessWidget {
  const _CategoryGrid({
    required this.modes,
    required this.labelsToFit,
    required this.tileBuilder,
  });

  static const _minTileWidth = 96.0;
  static const _spacing = FuncSpacing.sm;

  final List<M> modes;
  final List<M> labelsToFit;
  final Widget Function(M mode, Size size) tileBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = math.max(
            2,
            ((width + _spacing) / (_minTileWidth + _spacing)).floor(),
          );
          final tileWidth = (width - _spacing * (columns - 1)) / columns;
          final size = Size(
            tileWidth,
            _CategoryTile.heightFor(context, tileWidth, [
              for (final mode in labelsToFit) _label(context, mode),
            ]),
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
    this.selected = false,
    this.blocked = false,
    this.leadingIcon,
    this.semanticsHint,
    this.onTap,
  });

  static const _padding = EdgeInsets.symmetric(
    horizontal: FuncSpacing.sm,
    vertical: FuncSpacing.sm,
  );
  static const _iconSize = 16.0;
  static const _minHeight = 48.0;

  final String label;
  final bool selected;
  final bool blocked;
  final IconData? leadingIcon;
  final String? semanticsHint;
  final VoidCallback? onTap;

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.labelLarge;

  /// The height every tile takes: the tallest label wrapped at the width
  /// left beside the icon, at the painted style and text scale.
  static double heightFor(
    BuildContext context,
    double tileWidth,
    List<String> labels,
  ) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: TextAlign.center,
    );
    final textWidth =
        tileWidth - _padding.horizontal - _iconSize - FuncSpacing.xs;
    var tallest = 0.0;
    for (final label in labels) {
      painter.text = TextSpan(text: label, style: _style(context));
      painter.layout(maxWidth: math.max(0, textWidth));
      tallest = math.max(tallest, painter.height);
    }
    painter.dispose();
    return math.max(_minHeight, tallest + _padding.vertical);
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: _iconSize, color: foreground),
                  const SizedBox(width: FuncSpacing.xs),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: _style(context)?.copyWith(color: foreground),
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

/// A shown category in the editor: a tap hides it, a long press drags it
/// to a new place (the order changes live, it is saved on release), and
/// screen readers get move actions instead of the drag.
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

  /// The drag feedback is built in the overlay, outside the grid.
  final Size size;
  final String label;
  final bool blocked;
  final Arrangement<M> arrangement;
  final ValueChanged<Arrangement<M>> onReorder;
  final VoidCallback onDragEnd;

  /// Null when this is the last shown category.
  final VoidCallback? onHide;
  final ValueChanged<Arrangement<M>> onMove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final index = arrangement.shown.indexOf(mode);
    final last = arrangement.shown.length - 1;
    final tile = _CategoryTile(
      label: label,
      blocked: blocked,
      leadingIcon: onHide == null ? null : Icons.close,
      semanticsHint: onHide == null ? null : l10n.rankingHideCategory,
      onTap: onHide,
    );
    return DragTarget<M>(
      onWillAcceptWithDetails: (details) {
        final from = arrangement.shown.indexOf(details.data);
        if (from < 0 || details.data == mode) return false;
        onReorder(arrangement.reorder(from, index));
        return false;
      },
      builder: (context, _, _) => Semantics(
        customSemanticsActions: {
          if (index > 0)
            CustomSemanticsAction(label: l10n.rankingMoveEarlier): () =>
                onMove(arrangement.reorder(index, index - 1)),
          if (index < last)
            CustomSemanticsAction(label: l10n.rankingMoveLater): () =>
                onMove(arrangement.reorder(index, index + 1)),
        },
        child: LongPressDraggable<M>(
          data: mode,
          hapticFeedbackOnStart: false,
          onDragStarted: AppHaptics.longPress,
          onDragEnd: (_) => onDragEnd(),
          feedback: Material(
            type: MaterialType.transparency,
            child: SizedBox.fromSize(
              size: size,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: FuncShape.control,
                  boxShadow: kElevationToShadow[3],
                ),
                child: _CategoryTile(
                  label: label,
                  blocked: blocked,
                  leadingIcon: tile.leadingIcon,
                ),
              ),
            ),
          ),
          childWhenDragging: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: FuncShape.control,
              border: Border.all(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          child: tile,
        ),
      ),
    );
  }
}
