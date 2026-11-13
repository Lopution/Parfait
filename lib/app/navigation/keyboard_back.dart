import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../layout/input_modality.dart';
import '../pull_to_refresh.dart';

const _navigationCommandsChannel = MethodChannel('parfait/navigation_commands');

final _modifierLogicalKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

const _stackRoots = <String>[
  '/recommended',
  '/ranking',
  '/new',
  '/search',
  '/settings',
  '/me',
  '/reverse-image',
  '/downloads',
];

bool _isEditingFocused() {
  final focus = primaryFocus;
  return focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool _isContextOnScreen(BuildContext context) {
  if (!TickerMode.getValuesNotifier(context).value.enabled) return false;
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return false;
  final ro = context.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize || ro.size.isEmpty) return false;
  final view = View.maybeOf(context);
  if (view == null) return true;
  final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  return (ro.localToGlobal(Offset.zero) & ro.size).overlaps(screen);
}

String? _stackRootOfPath(String path) {
  for (final root in _stackRoots) {
    if (path == root || path.startsWith('$root/')) return root;
  }
  return null;
}

/// Marks a visible search entry (`SearchFieldButton` / narrow header icon) so
/// `Ctrl/Cmd+F` and `/` trigger it directly when on screen.
class SearchShortcutAnchor extends StatefulWidget {
  const SearchShortcutAnchor({
    super.key,
    required this.onTrigger,
    required this.child,
  });

  final VoidCallback onTrigger;
  final Widget child;

  @override
  State<SearchShortcutAnchor> createState() => _SearchShortcutAnchorState();
}

class _SearchShortcutAnchorState extends State<SearchShortcutAnchor> {
  static final List<_SearchShortcutAnchorState> _anchors = [];

  static bool triggerActive() {
    for (var i = _anchors.length - 1; i >= 0; i--) {
      final anchor = _anchors[i];
      if (anchor.mounted && _isContextOnScreen(anchor.context)) {
        anchor.widget.onTrigger();
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _anchors.add(this);
  }

  @override
  void dispose() {
    _anchors.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Global keyboard, mouse-back, navigation-command, and pointer-modality host
/// sitting inside `AppChrome` above `Router`.
///
/// * **Back:** `Escape` (unfocuses an `EditableText` first; otherwise pops via
///   `router`), `Alt+ArrowLeft` (Windows/Linux), `Cmd+[` (macOS), mouse back
///   button (`kBackMouseButton`), and `MethodChannel('parfait/navigation_commands')`
///   `'back'` calls from Windows `WM_APPCOMMAND`.
/// * **Search:** `Ctrl/Cmd+F` and `/` when not editing text.
/// * **Refresh:** `F5` and `Ctrl/Cmd+R` when not editing text, triggering the
///   active [PullToRefresh].
/// * **Focus-loss modifier guard:** clears stale modifier keys when window
///   or app focus is lost and re-syncs when regained.
class KeyboardBack extends StatefulWidget {
  const KeyboardBack({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  State<KeyboardBack> createState() => _KeyboardBackState();
}

class _KeyboardBackState extends State<KeyboardBack>
    with WidgetsBindingObserver {
  Future<Object?> Function(MethodCall)? _registeredHandler;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _registeredHandler = _handleNavigationCommand;
    _navigationCommandsChannel.setMethodCallHandler(_registeredHandler);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navigationCommandsChannel.setMethodCallHandler(null);
    _registeredHandler = null;
    super.dispose();
  }

  Future<Object?> _handleNavigationCommand(MethodCall call) async {
    switch (call.method) {
      case 'back':
        return await widget.router.routerDelegate.popRoute();
      case 'forward':
        return false;
      default:
        return false;
    }
  }

  void _releasePressedModifiers() {
    final keyboard = HardwareKeyboard.instance;
    final pressed = keyboard.physicalKeysPressed.toList();
    final timeStamp = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    for (final physical in pressed) {
      final logical = keyboard.lookUpLayout(physical);
      if (logical == null || !_modifierLogicalKeys.contains(logical)) continue;
      keyboard.handleKeyEvent(
        KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: timeStamp,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _releasePressedModifiers();
    if (state == AppLifecycleState.resumed) {
      unawaited(HardwareKeyboard.instance.syncKeyboardState());
    }
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    _releasePressedModifiers();
    if (event.state == ViewFocusState.focused) {
      unawaited(HardwareKeyboard.instance.syncKeyboardState());
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if ((event.buttons & kBackMouseButton) != 0) {
      unawaited(widget.router.routerDelegate.popRoute());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): const _BackIntent(
        unfocusEditing: true,
      ),
      if (isMac) ...{
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
            const _BackIntent(unfocusEditing: false),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            const _RefreshIntent(),
      } else ...{
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            const _BackIntent(unfocusEditing: false),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _RefreshIntent(),
      },
      const SingleActivator(LogicalKeyboardKey.slash): const _SearchIntent(),
      const SingleActivator(LogicalKeyboardKey.f5): const _RefreshIntent(),
    };

    return InputModalityScope(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        child: Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              _BackIntent: _BackAction(widget.router),
              _SearchIntent: _SearchAction(widget.router),
              _RefreshIntent: _RefreshAction(widget.router),
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _BackIntent extends Intent {
  const _BackIntent({required this.unfocusEditing});

  final bool unfocusEditing;
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}

class _BackAction extends Action<_BackIntent> {
  _BackAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_BackIntent intent) =>
      intent.unfocusEditing || !_isEditingFocused();

  @override
  Object? invoke(_BackIntent intent) {
    if (intent.unfocusEditing && _isEditingFocused()) {
      primaryFocus!.unfocus();
      return null;
    }
    // False at the start page's root: nothing left to go back to.
    return router.routerDelegate.popRoute();
  }
}

class _SearchAction extends Action<_SearchIntent> {
  _SearchAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_SearchIntent intent) => !_isEditingFocused();

  @override
  Object? invoke(_SearchIntent intent) {
    if (_SearchShortcutAnchorState.triggerActive()) return null;
    final path = router.routerDelegate.currentConfiguration.uri.path;
    if (path.endsWith('/search/input')) return null;
    final root = _stackRootOfPath(path);
    final location = (root == null || root == '/search')
        ? '/search/input'
        : '$root/search/input';
    unawaited(router.push<void>(location));
    return null;
  }
}

class _RefreshAction extends Action<_RefreshIntent> {
  _RefreshAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_RefreshIntent intent) => !_isEditingFocused();

  @override
  Object? invoke(_RefreshIntent intent) {
    final focusContext =
        primaryFocus?.context ??
        router.routerDelegate.navigatorKey.currentContext;
    PullToRefresh.triggerActive(focusContext);
    return null;
  }
}
