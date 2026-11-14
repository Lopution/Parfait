import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';

import '../../core/debug/frame_probe.dart';
import '../layout/input_modality.dart';
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

/// Presents [actions] beside the pointer when triggered by a pointer device (mouse
/// or trackpad, including on tablets); on touch or stylus forms the secondary
/// click does what the long press does ([onLongPress]).
///
/// A pointer menu is the M3 popup menu opened at [position] (a global point,
/// as a secondary tap reports it): items announce as buttons with their
/// labels, arrow keys move between them and Esc closes the menu. Selecting
/// one runs its [DisplayAction.onSelected] after the menu has closed.
Future<void> showDisplayActions(
  BuildContext context, {
  required Offset position,
  required List<DisplayAction> actions,
  required VoidCallback onLongPress,
  PointerDeviceKind? kind,
}) {
  final modality =
      (kind != null ? inputModalityForPointerKind(kind) : null) ??
      InputModalityScope.maybeOf(context) ??
      defaultInputModalityFor(defaultTargetPlatform);
  // Touch and stylus interactions (and pointers with nothing to offer) keep
  // the long press: the bottom panel, or the gesture's own direct action.
  if (modality != InputModality.pointer || actions.isEmpty) {
    onLongPress();
    return Future.value();
  }
  // The same Navigator [showAppContextMenu] pushes on: a branch page's
  // overlay starts below the top bar and beside the rail, so the pointer's
  // global position must be taken in that overlay or the menu is offset.
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
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
          // QUAL-05: the rows live exactly as long as the menu route, entry
          // animation to disposal, so a probe recording names the menu as a
          // scene. The stock popup route owns its animation, and its class
          // is private, so this bracket rides the content instead.
          child: ProbeScene(
            scene: 'menu',
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
        ),
    ],
  );
}
