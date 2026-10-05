import 'package:material_ui/material_ui.dart';

import '../motion/press_scale.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';

/// Slot-based entity row — the shared object-presentation contract
/// (roadmap §5.2). The base widget owns identification (cover, title,
/// author) and the primary tap/long-press actions; rank, dates, progress
/// and update markers all arrive through slots — a page never hand-draws
/// its own variant of the same row.
///
/// `NovelEntry` wraps this with the novel card chrome; management lists
/// (watchlist, local novels, download tasks) use the row bare.
class EntityRow extends StatelessWidget {
  const EntityRow({
    super.key,
    required this.leading,
    required this.title,
    this.titleLeading,
    this.subtitle,
    this.meta,
    this.badge,
    this.progress,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.semanticLabel,
    this.padding = const EdgeInsets.all(FuncSpacing.md),
  }) : assert(
         progress == null || (progress >= 0 && progress <= 1),
         'progress is a 0..1 fraction; null means "no record"',
       ),
       assert(
         !selected || trailing == null,
         'a selected row is a single selection unit — it cannot carry a '
         'secondary action (M3); leave trailing null',
       );

  /// Identification slot — cover image, icon tile, any visual anchor.
  final Widget leading;

  /// Already-localized primary text.
  final String title;

  /// Marker at the start of the title line, baseline-aligned with it — the
  /// ranking position ([EntityRankLabel]).
  final Widget? titleLeading;

  /// Secondary line — the author by convention.
  final String? subtitle;

  /// Semantic meta line (word count, date, progress text…). Rendered with
  /// the shared caption token via [EntityMetaText]; reuse that widget when
  /// the same line must appear outside a row (history grid cells).
  final String? meta;

  /// Overlay badge pinned to the leading slot's top-left corner — "New"
  /// markers. Use [EntityBadge] for the shared container.
  final Widget? badge;

  /// Reading-progress slot. `null` = no progress record → nothing renders;
  /// `0.0` = a real record at the start → an empty bar still renders.
  /// The two states are not interchangeable (W5 null↔0 boundary).
  final double? progress;

  /// Trailing action slot (chevron, overflow button, bookmark toggle).
  /// Selection-mode consumers leave it null: a selected row is a single
  /// selection unit and cannot carry nested secondary actions (M3).
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Management-mode selected state: paints the whole row with the
  /// selection surface and appends a check mark.
  final bool selected;

  /// Accessibility label for the whole row. Defaults to
  /// `'$title, $subtitle'` (or just [title] without a subtitle).
  final String? semanticLabel;

  /// Inner padding — the historical novel cards used `EdgeInsets.all(10)`.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    // Selected rows paint the whole row primaryContainer, so every glyph on
    // it switches to the on-color; secondary lines keep a slight alpha so
    // the primary/secondary hierarchy survives.
    final selectedText = colorScheme.onPrimaryContainer;
    final selectedSecondary = selectedText.withValues(alpha: 0.8);
    const radius = FuncShape.control;
    final label =
        semanticLabel ?? (subtitle == null ? title : '$title, $subtitle');

    Widget leadingSlot = leading;
    final badgeWidget = badge;
    if (badgeWidget != null) {
      leadingSlot = Stack(
        clipBehavior: Clip.none,
        children: [
          leading,
          Positioned(left: 0, top: 0, child: badgeWidget),
        ],
      );
    }

    return PressScale(
      child: Semantics(
        container: true,
        button: onTap != null || onLongPress != null,
        selected: selected,
        label: label,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Material(
          type: selected ? MaterialType.canvas : MaterialType.transparency,
          color: selected ? colorScheme.primaryContainer : null,
          borderRadius: radius,
          // Only the selection surface needs the rounded clip — paying a
          // saveLayer per unselected feed row is wasted raster work.
          clipBehavior: selected ? Clip.antiAlias : Clip.none,
          child: InkWell(
            // The outer Semantics already exposes the actions — the ink
            // response must not announce a second unlabeled button.
            excludeFromSemantics: true,
            onTap: onTap,
            onLongPress: onLongPress,
            // A long-press host plays its own AppHaptics role; the ink
            // response's vibration would double it.
            enableFeedback: onLongPress == null,
            borderRadius: radius,
            child: Padding(
              padding: padding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The row's a11y identity is the Semantics label above —
                  // the cover and text children must not repeat it inside
                  // the merged label (a labeled node absorbs descendant
                  // text). Only [trailing] keeps its own node so embedded
                  // actions stay reachable.
                  ExcludeSemantics(child: leadingSlot),
                  const SizedBox(width: FuncSpacing.md),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _titleLine(
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: selected ? selectedText : null,
                              ),
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: FuncSpacing.xs),
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: selected
                                  ? tokens.caption.copyWith(
                                      color: selectedSecondary,
                                    )
                                  : tokens.caption,
                            ),
                          ],
                          if (meta != null) ...[
                            const SizedBox(height: FuncSpacing.xs),
                            EntityMetaText(
                              meta!,
                              color: selected ? selectedSecondary : null,
                            ),
                          ],
                          if (progress != null) ...[
                            const SizedBox(height: FuncSpacing.xs),
                            LinearProgressIndicator(value: progress),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: FuncSpacing.sm),
                    trailing!,
                  ],
                  if (selected) ...[
                    const SizedBox(width: FuncSpacing.sm),
                    Icon(
                      Icons.check_circle,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleLine(Widget text) {
    final leading = titleLeading;
    if (leading == null) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        leading,
        const SizedBox(width: FuncSpacing.xs),
        Expanded(child: text),
      ],
    );
  }
}

/// Shared meta-line presentation: the caption token, one line, ellipsized.
/// [EntityRow] renders its `meta` slot through this; grid cells that carry
/// the same kind of line (the history date under a card) reuse it directly
/// so the meta look exists in exactly one place.
class EntityMetaText extends StatelessWidget {
  const EntityMetaText(this.text, {super.key, this.color});

  final String text;

  /// Overrides the caption color — [EntityRow] passes the selected-state
  /// on-container color; null keeps the shared caption token.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final caption = FuncSemanticTokens.of(context).caption;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: color == null ? caption : caption.copyWith(color: color),
    );
  }
}

/// Ranking position at the start of a title line: plain digits in
/// `titleSmall`, bold and tabular, `onSurface` — no medal, no top-three
/// color. `IllustCard(rank:)` and `NovelEntry(ranking:)` both render it so
/// the marker cannot drift into two look-alikes; the position never sits on
/// the artwork.
class EntityRankLabel extends StatelessWidget {
  const EntityRankLabel(this.rank, {super.key});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '$rank',
      style: theme.textTheme.titleSmall!
          .copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          )
          .tabular,
    );
  }
}

/// Corner badge over artwork: one scrim, shape and type scale for every
/// marker, legible on light and dark images alike. The look ignores the
/// theme brightness — the badge sits on the image, not on the page — and
/// no badge picks its own color: R-18 and AI differ by their text.
class EntityBadge extends StatelessWidget {
  const EntityBadge({super.key, this.icon, this.label, this.semanticsLabel})
    : assert(icon != null || label != null, 'a badge shows an icon or text');

  /// Minimum height; larger text scales grow the badge instead of clipping.
  static const double height = 20;
  static const double iconSize = 14;

  /// Badge geometry rather than page spacing, so it stays off the
  /// [FuncSpacing] ladder.
  static const double _inset = 6;

  final IconData? icon;
  final String? label;

  /// Spoken instead of the visible content — an icon-only badge needs it,
  /// and a terse label ("AI") reads better spelled out.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    final label = this.label;
    final style = Theme.of(context).textTheme.labelSmall!
        .copyWith(color: FuncTokens.onImageControl, fontWeight: FontWeight.w600)
        .tabular;
    final badge = DecoratedBox(
      decoration: const BoxDecoration(
        color: FuncTokens.imageControl,
        borderRadius: FuncShape.badge,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: height),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _inset),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, size: iconSize, color: FuncTokens.onImageControl),
              if (icon != null && label != null)
                const SizedBox(width: FuncSpacing.xxs),
              if (label != null) Text(label, style: style, softWrap: false),
            ],
          ),
        ),
      ),
    );
    final semanticsLabel = this.semanticsLabel;
    if (semanticsLabel == null) return badge;
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: badge,
    );
  }
}
