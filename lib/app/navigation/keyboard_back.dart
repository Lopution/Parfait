import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

/// Esc goes back, the way the system back does: through the router, so a
/// dialog or sheet closes first, a page's PopScope and the home shell's
/// "back to the start page" still apply. A menu or viewer that
/// handles Esc itself is nearer the focus and gets it first.
///
/// Two differences from the system back: Esc in a text field only leaves
/// the field, and at the start page's root it does nothing rather than
/// close the app.
///
/// Esc gets its own intent: WidgetsApp maps it to DismissIntent, which
/// every page route answers with a disabled action, so it never got past
/// the page.
class KeyboardBack extends StatelessWidget {
  const KeyboardBack({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _BackIntent(),
      },
      child: Actions(actions: {_BackIntent: _BackAction(router)}, child: child),
    );
  }
}

class _BackIntent extends Intent {
  const _BackIntent();
}

class _BackAction extends Action<_BackIntent> {
  _BackAction(this.router);

  final GoRouter router;

  @override
  Object? invoke(_BackIntent intent) {
    final focus = primaryFocus;
    final editing =
        focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (editing) {
      focus!.unfocus();
      return null;
    }
    // False at the start page's root: nothing left to go back to.
    return router.routerDelegate.popRoute();
  }
}
