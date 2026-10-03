import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';

/// Upper bound on a menu's width (the M3 menu maximum). Long translations
/// truncate inside it instead of widening the menu.
const double kAppMenuMaxWidth = 280;

/// One row of an [AppMenuButton].
@immutable
class AppMenuEntry<T> {
  const AppMenuEntry({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.checked,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;

  /// Non-null makes the row a checkable item: a trailing check while true,
  /// and checked/unchecked semantics either way.
  final bool? checked;
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
    this.icon = const Icon(Icons.more_vert),
    this.style,
    this.anchorBuilder,
  });

  final List<AppMenuEntry<T>> entries;

  /// Receives the anchor's own context — callers that place a popover next
  /// to the button (share) need its position.
  final void Function(BuildContext anchorContext, T value) onSelected;

  /// Defaults to the platform "show menu" tooltip. Ignored when
  /// [anchorBuilder] supplies its own anchor.
  final String? tooltip;

  final Widget icon;

  /// Forwarded to the default [IconButton] anchor (the over-artwork
  /// palette, for instance).
  final ButtonStyle? style;

  /// Replaces the default icon button; call `toggle` to open or close.
  final Widget Function(BuildContext context, VoidCallback toggle)?
  anchorBuilder;

  @override
  State<AppMenuButton<T>> createState() => _AppMenuButtonState<T>();
}

class _AppMenuButtonState<T> extends State<AppMenuButton<T>> {
  final _controller = MenuController();
  bool _open = false;
  BuildContext? _anchorContext;

  void _setOpen(bool open) {
    if (!mounted || _open == open) return;
    setState(() => _open = open);
  }

  Widget _item(AppMenuEntry<T> entry) {
    final checked = entry.checked;
    Widget item = MenuItemButton(
      leadingIcon: entry.icon == null ? null : Icon(entry.icon, size: 20),
      trailingIcon: checked == true ? const Icon(Icons.check, size: 18) : null,
      onPressed: entry.enabled
          ? () => widget.onSelected(_anchorContext ?? context, entry.value)
          : null,
      child: Text(entry.label, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _controller.close();
      },
      child: MenuAnchor(
        controller: _controller,
        consumeOutsideTap: true,
        animated: MotionTokens.enabled(context),
        // Constrained: the default lets the panel grow past the width cap
        // (and the screen) and clips long labels instead of truncating.
        crossAxisUnconstrained: false,
        style: const MenuStyle(
          maximumSize: WidgetStatePropertyAll(
            Size(kAppMenuMaxWidth, double.infinity),
          ),
        ),
        onOpen: () => _setOpen(true),
        onClose: () => _setOpen(false),
        menuChildren: [for (final entry in widget.entries) _item(entry)],
        builder: (anchorContext, controller, _) {
          _anchorContext = anchorContext;
          void toggle() =>
              controller.isOpen ? controller.close() : controller.open();
          return widget.anchorBuilder?.call(anchorContext, toggle) ??
              IconButton(
                tooltip:
                    widget.tooltip ??
                    MaterialLocalizations.of(context).showMenuTooltip,
                style: widget.style,
                icon: widget.icon,
                onPressed: toggle,
              );
        },
      ),
    );
  }
}
