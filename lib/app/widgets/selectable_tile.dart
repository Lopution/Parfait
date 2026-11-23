import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../motion/state_icon_switcher.dart';
import '../theme/func_semantic_tokens.dart';
import 'display_actions.dart';
import '../icons/ui_icons.dart';

/// A grid tile that becomes a selection unit in a list's management mode
/// (history, watch later). While [managing], the whole tile toggles on tap,
/// long press, or keyboard activation (`Enter` / `Space`), and the child's
/// own gestures, focus, and semantic actions are blocked — M3: no nested
/// actions inside a selectable item; a selected tile carries a tinted frame
/// and a check, and is announced selected. Outside management a long press
/// runs [onLongPress] when given (history enters management), otherwise the
/// child keeps its own (watch later's cards open their action sheet).
class SelectableTile extends StatefulWidget {
  const SelectableTile({
    super.key,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.child,
    this.onLongPress,
  });

  final bool managing;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;
  final Widget child;

  @override
  State<SelectableTile> createState() => _SelectableTileState();
}

class _SelectableTileState extends State<SelectableTile> {
  var _focused = false;

  @override
  void didUpdateWidget(SelectableTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.managing && _focused) _focused = false;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final managing = widget.managing;
    final selected = widget.selected;
    return Semantics(
      selected: managing ? selected : null,
      child: FocusableActionDetector(
        enabled: managing,
        onShowFocusHighlight: (show) {
          if (_focused != show) setState(() => _focused = show);
        },
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onToggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: managing ? widget.onToggle : null,
          onLongPress: managing ? widget.onToggle : widget.onLongPress,
          // A selection is already on screen in management mode, so the
          // right-click keeps toggling; outside it the PC offers the entry
          // beside the pointer (R11).
          onSecondaryTapUp: managing
              ? (details) => widget.onToggle()
              : widget.onLongPress == null
              ? null
              : (details) => unawaited(
                  showDisplayActions(
                    context,
                    position: details.globalPosition,
                    kind: details.kind,
                    onLongPress: widget.onLongPress!,
                    actions: [
                      DisplayAction(
                        icon: UiIcons.checklist,
                        label: context.l10n.manage,
                        onSelected: widget.onLongPress!,
                      ),
                    ],
                  ),
                ),
          child: Stack(
            children: [
              ExcludeFocus(
                excluding: managing,
                child: AbsorbPointer(absorbing: managing, child: widget.child),
              ),
              if (managing)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: FuncShape.card,
                        border: selected || _focused
                            ? Border.all(color: colorScheme.primary, width: 2)
                            : null,
                        color: selected
                            ? colorScheme.primary.withValues(alpha: 0.14)
                            : null,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: FuncSpacing.sm,
                right: FuncSpacing.sm,
                child: IgnorePointer(
                  child: StateIconSwitcher(
                    value: selected,
                    child: selected
                        ? Icon(UiIcons.checkCircle, color: colorScheme.primary)
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
