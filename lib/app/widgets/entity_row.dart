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
    this.subtitle,
    this.meta,
    this.badge,
    this.progress,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.semanticLabel,
    this.padding = const EdgeInsets.all(10),
  }) : assert(
         progress == null || (progress >= 0 && progress <= 1),
         'progress is a 0..1 fraction; null means "no record"',
       );

  /// Identification slot — cover image, icon tile, any visual anchor.
  final Widget leading;

  /// Already-localized primary text.
  final String title;

  /// Secondary line — the author by convention.
  final String? subtitle;

  /// Semantic meta line (word count, date, progress text…). Rendered with
  /// the shared caption token via [EntityMetaText]; reuse that widget when
  /// the same line must appear outside a row (history grid cells).
  final String? meta;

  /// Overlay badge pinned to the leading slot's top-left corner — rank
  /// pills, "New" markers. Use [EntityBadge] for the shared container.
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
    const radius = BorderRadius.all(Radius.circular(4));
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
          color: selected ? colorScheme.secondaryContainer : null,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // The outer Semantics already exposes the actions — the ink
            // response must not announce a second unlabeled button.
            excludeFromSemantics: true,
            onTap: onTap,
            onLongPress: onLongPress,
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.caption,
                            ),
                          ],
                          if (meta != null) ...[
                            const SizedBox(height: 4),
                            EntityMetaText(meta!),
                          ],
                          if (progress != null) ...[
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: progress),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check_circle, color: colorScheme.primary),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared meta-line presentation: the caption token, one line, ellipsized.
/// [EntityRow] renders its `meta` slot through this; grid cells that carry
/// the same kind of line (the history date under a card) reuse it directly
/// so the meta look exists in exactly one place.
class EntityMetaText extends StatelessWidget {
  const EntityMetaText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: FuncSemanticTokens.of(context).caption,
    );
  }
}

/// The one badge container every object surface shares — illust card
/// corners and entity-row overlays use the same radius, fill and padding.
/// The default fill is the neutral dark scrim; semantic variants inject a
/// [ColorScheme] color (R-18 → primary, AI → error, rank → primary).
class EntityBadge extends StatelessWidget {
  const EntityBadge({super.key, required this.child, this.color});

  final Widget child;

  /// Semantic fill color; `null` paints the neutral scrim shared by the
  /// informational badges (page count, ugoira marker).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? const Color(0x99343838),
        borderRadius: BorderRadius.circular(5),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: FuncTokens.lightBackground),
        child: IconTheme(
          data: const IconThemeData(
            color: FuncTokens.lightBackground,
            size: 22,
          ),
          child: child,
        ),
      ),
    );
  }
}
