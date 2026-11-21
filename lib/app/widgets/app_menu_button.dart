import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import '../icons/ui_icons.dart';

/// Upper bound on a menu's width. Long translations truncate inside it
/// instead of widening the menu past the viewport.
const double kAppMenuMaxWidth = 360;

/// Which edge of its anchor a menu lines up with. The menu opens below the
/// anchor either way.
enum AppMenuEdge {
  /// The menu's start edge under the anchor's start edge: a dropdown
  /// button at the start of a row.
  start,

  /// The menu's end edge under the anchor's end edge (M3): a ⋮ button or
  /// a value at the end of a row or toolbar.
  end,
}

/// One row of an [AppMenuButton].
@immutable
class AppMenuEntry<T> {
  const AppMenuEntry({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.checked,
    this.destructive = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;

  /// Non-null makes the row a checkable item: a trailing check while true,
  /// and checked/unchecked semantics either way.
  final bool? checked;

  /// Paints the row in the danger color (delete and other irreversible
  /// actions).
  final bool destructive;
}

/// Overflow or choice menu that closes like a native popup window.
///
/// `PopupMenuButton` routes its menu behind a `ModalBarrier` that only
/// dismisses on a tap — a drag outside the menu keeps it open. Here the
/// menu is a [MenuAnchor] with `consumeOutsideTap`: a pointer going down
/// anywhere outside closes it and that touch never reaches the page below
/// (no scroll, no tap). Back closes the menu before the page.
class AppMenuButton<T> extends StatefulWidget {
  const AppMenuButton({
    super.key,
    required this.entries,
    required this.onSelected,
    this.tooltip,
    this.icon = const Icon(UiIcons.more),
    this.anchorBuilder,
    this.edge = AppMenuEdge.end,
  });

  final List<AppMenuEntry<T>> entries;

  /// Receives the anchor's own context — callers that place a popover next
  /// to the button (share) need its position.
  final void Function(BuildContext anchorContext, T value) onSelected;

  /// Defaults to the platform "show menu" tooltip. Ignored when
  /// [anchorBuilder] supplies its own anchor.
  final String? tooltip;

  final Widget icon;

  /// Replaces the default icon button; call `toggle` to open or close.
  final Widget Function(BuildContext context, VoidCallback toggle)?
  anchorBuilder;

  /// The anchor edge the menu lines up with; [AppMenuEdge.end] unless the
  /// anchor sits at the start of its row.
  final AppMenuEdge edge;

  @override
  State<AppMenuButton<T>> createState() => _AppMenuButtonState<T>();
}

class _AppMenuButtonState<T> extends State<AppMenuButton<T>> {
  final _controller = MenuController();
  bool _open = false;
  BuildContext? _anchorContext;

  /// How far the menu sits in from the anchor edge it lines up with, so it
  /// keeps [FuncSpacing.sm] off that side of the screen; measured on each
  /// opening. An anchor further in keeps the menu lined up with it.
  double _edgeInset = 0;

  void _setOpen(bool open) {
    if (!mounted || _open == open) return;
    setState(() => _open = open);
  }

  /// MenuAnchor lines the menu's start edge up with the anchor's, and the
  /// menu's width is only known at layout. Laid out in the mirrored
  /// direction, its start edge is the ambient end edge.
  TextDirection get _menuDirection {
    final direction = Directionality.of(context);
    return switch (widget.edge) {
      AppMenuEdge.start => direction,
      AppMenuEdge.end => switch (direction) {
        TextDirection.ltr => TextDirection.rtl,
        TextDirection.rtl => TextDirection.ltr,
      },
    };
  }

  void _openMenu() {
    final anchor = _anchorContext!.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final rect = MatrixUtils.transformRect(
      anchor.getTransformTo(overlay),
      Offset.zero & anchor.size,
    );
    final gap = switch (_menuDirection) {
      TextDirection.ltr => rect.left,
      TextDirection.rtl => overlay.size.width - rect.right,
    };
    setState(() => _edgeInset = math.max(0, FuncSpacing.sm - gap));
    _controller.open();
  }

  Widget _item(AppMenuEntry<T> entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final checked = entry.checked;
    final isChecked = checked == true;
    final danger = entry.destructive ? tokens.danger : null;
    final foreground = danger ?? (isChecked ? scheme.primary : null);
    final iconColor =
        danger ?? (isChecked ? scheme.primary : scheme.onSurfaceVariant);
    Widget item = MenuItemButton(
      style: MenuItemButton.styleFrom(
        backgroundColor: isChecked ? tokens.brandTintWeak : null,
        foregroundColor: foreground,
        iconColor: iconColor,
        shape: const RoundedRectangleBorder(borderRadius: FuncShape.control),
        minimumSize: const Size(136, 36),
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.md,
          vertical: FuncSpacing.sm,
        ),
      ),
      leadingIcon: entry.icon == null ? null : Icon(entry.icon, size: 18),
      trailingIcon: isChecked ? const Icon(UiIcons.check, size: 16) : null,
      onPressed: entry.enabled
          ? () => widget.onSelected(_anchorContext ?? context, entry.value)
          : null,
      child: Text(
        entry.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isChecked ? const TextStyle(fontWeight: FontWeight.w500) : null,
      ),
    );
    if (checked != null) {
      item = MergeSemantics(
        child: Semantics(checked: checked, child: item),
      );
    }
    return item;
  }

  @override
  Widget build(BuildContext context) {
    // The menu is laid out in [_menuDirection]; the anchor and the items
    // keep the ambient direction.
    final direction = Directionality.of(context);
    Widget ambient(Widget child) =>
        Directionality(textDirection: direction, child: child);
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _controller.close();
      },
      child: Directionality(
        textDirection: _menuDirection,
        child: _anchor(ambient),
      ),
    );
  }

  Widget _anchor(Widget Function(Widget child) ambient) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final hairline =
        theme.extension<FuncSemanticTokens>()?.brandHairline ??
        scheme.outlineVariant;
    final surface = dark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLowest;
    return MenuAnchor(
      controller: _controller,
      consumeOutsideTap: true,
      animated: MotionTokens.enabled(context),
      // Constrained: the default lets the panel grow past the width cap
      // (and the screen) and clips long labels instead of truncating.
      crossAxisUnconstrained: false,
      // In the menu's direction, a positive x offset moves it inward; y adds a
      // breathing gap below the trigger so the popover never fuses with it.
      alignmentOffset: Offset(_edgeInset, FuncSpacing.xs),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(3),
        shadowColor: WidgetStatePropertyAll(
          scheme.shadow.withValues(alpha: dark ? 0.45 : 0.16),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: FuncShape.card,
            side: BorderSide(color: hairline),
          ),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(FuncSpacing.xs)),
        maximumSize: const WidgetStatePropertyAll(
          Size(kAppMenuMaxWidth, double.infinity),
        ),
      ),
      onOpen: () => _setOpen(true),
      onClose: () => _setOpen(false),
      menuChildren: [
        for (var i = 0; i < widget.entries.length; i++)
          ambient(
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : FuncSpacing.xxs),
              child: _item(widget.entries[i]),
            ),
          ),
      ],
      builder: (_, controller, _) => ambient(
        Builder(
          builder: (anchorContext) {
            _anchorContext = anchorContext;
            void toggle() =>
                controller.isOpen ? controller.close() : _openMenu();
            return widget.anchorBuilder?.call(anchorContext, toggle) ??
                IconButton(
                  tooltip:
                      widget.tooltip ??
                      MaterialLocalizations.of(context).showMenuTooltip,
                  icon: widget.icon,
                  onPressed: toggle,
                );
          },
        ),
      ),
    );
  }
}
