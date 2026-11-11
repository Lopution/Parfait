import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../motion/state_icon_switcher.dart';
import '../theme/func_semantic_tokens.dart';
import 'display_actions.dart';

/// A grid tile that becomes a selection unit in a list's management mode
/// (history, watch later). While [managing], the whole tile toggles on tap
/// or long press and the child's own gestures and semantic actions are
/// blocked — M3: no nested actions inside a selectable item; a selected
/// tile carries a tinted frame and a check, and is announced selected.
/// Outside management a long press runs [onLongPress] when given (history
/// enters management), otherwise the child keeps its own (watch later's
/// cards open their action sheet).
class SelectableTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: managing ? selected : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: managing ? onToggle : null,
        onLongPress: managing ? onToggle : onLongPress,
        // A selection is already on screen in management mode, so the
        // right-click keeps toggling; outside it the PC offers the entry
        // beside the pointer (R11).
        onSecondaryTapUp: managing
            ? (details) => onToggle()
            : onLongPress == null
            ? null
            : (details) => unawaited(
                showDisplayActions(
                  context,
                  position: details.globalPosition,
                  onLongPress: onLongPress!,
                  actions: [
                    DisplayAction(
                      icon: Icons.checklist_outlined,
                      label: context.l10n.manage,
                      onSelected: onLongPress!,
                    ),
                  ],
                ),
              ),
        child: Stack(
          children: [
            AbsorbPointer(absorbing: managing, child: child),
            if (managing)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: FuncShape.card,
                      border: selected
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
                      ? Icon(Icons.check_circle, color: colorScheme.primary)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
