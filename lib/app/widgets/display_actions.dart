import 'package:material_ui/material_ui.dart';

import '../layout/form_factor.dart';
import '../motion/app_overlays.dart';
import '../theme/func_semantic_tokens.dart';
import 'app_menu_button.dart' show kAppMenuMaxWidth;

/// One action a long press and a pointer's secondary click offer (R11):
/// the same icon, label and result in the bottom panel and in the menu.
@immutable
class DisplayAction {
  const DisplayAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool enabled;
}

/// Presents [actions] beside the pointer on a PC; on every other form the
/// secondary click does what the long press does ([onLongPress]).
///
/// A PC menu is the M3 popup menu opened at [position] (a global point, as
/// a secondary tap reports it): items announce as buttons with their
/// labels, arrow keys move between them and Esc closes the menu. Selecting
/// one runs its [DisplayAction.onSelected] after the menu has closed.
Future<void> showDisplayActions(
  BuildContext context, {
  required Offset position,
  required List<DisplayAction> actions,
  required VoidCallback onLongPress,
}) {
  // A touch form (and a PC with nothing to offer) keeps the long press:
  // the bottom panel, or the gesture's own direct action.
  if (FormFactor.of(context) != FormFactor.pc || actions.isEmpty) {
    onLongPress();
    return Future.value();
  }
  final overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()!
          as RenderBox;
  final local = overlay.globalToLocal(position);
  return showAppContextMenu<void>(
    context: context,
    position: RelativeRect.fromRect(
      local & Size.zero,
      Offset.zero & overlay.size,
    ),
    // The same width cap as the app's overflow menus, so a long label
    // truncates instead of widening the menu past the window.
    constraints: const BoxConstraints(
      minWidth: 200,
      maxWidth: kAppMenuMaxWidth,
    ),
    items: [
      for (final action in actions)
        PopupMenuItem<void>(
          enabled: action.enabled,
          onTap: action.onSelected,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(action.icon, size: 20),
              const SizedBox(width: FuncSpacing.md),
              Flexible(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
