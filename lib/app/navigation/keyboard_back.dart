import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/navigation/home_destination.dart';
import '../layout/input_modality.dart';
import '../layout/window_layout_spec.dart';
import '../pull_to_refresh.dart';
import '../widgets/feed/feed_selection.dart';
import 'forward_history.dart';
import 'keyboard_shortcuts_sheet.dart';

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

const _overlayRoots = <String>['/me', '/reverse-image', '/downloads'];

const _stackRoots = <String>[
  '/recommended',
  '/ranking',
  '/new',
  '/search',
  '/settings',
  ..._overlayRoots,
];

bool _isContextOnScreen(BuildContext context) =>
    isRenderBoxVisibleOnScreen(context);

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

  /// Invokes the most recently mounted on-screen [SearchShortcutAnchor].
  static bool triggerActive() => _SearchShortcutAnchorState.triggerActive();

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

const _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
];

/// Global keyboard, mouse-back, navigation-command, and pointer-modality host
/// sitting inside `AppChrome` above `Router`.
///
/// * **Back:** `Escape` (unfocuses an `EditableText` first; otherwise pops via
///   `router`), `Alt+ArrowLeft` (Windows/Linux), `Cmd+[` (macOS/iOS), mouse back
///   button (`kBackMouseButton`), and `MethodChannel('parfait/navigation_commands')`
///   `'back'` calls from Windows `WM_APPCOMMAND`.
/// * **Search:** `Ctrl/Cmd+F`, `Ctrl/Cmd+K`, and `/` when not editing text.
/// * **Navigation & Shell:** `Ctrl/Cmd+,` (settings), `Ctrl/Cmd+1..5` (home tabs),
///   and `Ctrl/Cmd+B` (toggle rail when expandable).
/// * **Refresh:** `F5` and `Ctrl/Cmd+R` when not editing text, triggering the
///   active [PullToRefresh].
/// * **Focus-loss modifier guard:** clears stale modifier keys when window
///   or app focus is lost and re-syncs when regained.
class KeyboardBack extends StatefulWidget {
  const KeyboardBack({
    super.key,
    required this.router,
    this.destinations = HomeDestination.values,
    this.onToggleRail,
    required this.child,
  });

  final GoRouter router;
  final List<HomeDestination> destinations;
  final VoidCallback? onToggleRail;
  final Widget child;

  @override
  State<KeyboardBack> createState() => _KeyboardBackState();
}

class _KeyboardBackState extends State<KeyboardBack>
    with WidgetsBindingObserver {
  static Future<Object?> Function(MethodCall)? _activeChannelHandler;
  Future<Object?> Function(MethodCall)? _registeredHandler;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final handler = _handleNavigationCommand;
    _registeredHandler = handler;
    _activeChannelHandler = handler;
    _navigationCommandsChannel.setMethodCallHandler(handler);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_activeChannelHandler, _registeredHandler)) {
      _activeChannelHandler = null;
      _navigationCommandsChannel.setMethodCallHandler(null);
    }
    _registeredHandler = null;
    super.dispose();
  }

  static const _hardwareNavDebounce = Duration(milliseconds: 120);

  final Set<int> _heldBackPointers = <int>{};
  final Set<int> _heldForwardPointers = <int>{};

  String? _lastPointerNavDir;
  DateTime? _lastPointerNavAt;
  int _lastPointerPushGen = -1;

  String? _lastChannelNavDir;
  DateTime? _lastChannelNavAt;
  int _lastChannelPushGen = -1;

  ForwardHistoryStack get _history =>
      ForwardHistoryStack.ofRouter(widget.router);

  bool _isPointerHeldForDirection(String direction) => switch (direction) {
    'back' => _heldBackPointers.isNotEmpty,
    'forward' => _heldForwardPointers.isNotEmpty,
    _ => false,
  };

  bool _shouldSuppressCrossSource(
    String direction, {
    required bool fromChannel,
  }) {
    final now = DateTime.now();
    final gen = _history.pushGeneration;
    if (fromChannel) {
      if (_isPointerHeldForDirection(direction)) {
        return true;
      }
      if (_lastPointerNavDir == direction &&
          _lastPointerPushGen == gen &&
          _lastPointerNavAt != null &&
          now.difference(_lastPointerNavAt!) < _hardwareNavDebounce) {
        _lastPointerNavDir = null;
        _lastPointerNavAt = null;
        return true;
      }
      _lastChannelNavDir = direction;
      _lastChannelNavAt = now;
      _lastChannelPushGen = gen;
      return false;
    }
    if (_lastChannelNavDir == direction &&
        _lastChannelPushGen == gen &&
        _lastChannelNavAt != null &&
        now.difference(_lastChannelNavAt!) < _hardwareNavDebounce) {
      _lastChannelNavDir = null;
      _lastChannelNavAt = null;
      return true;
    }
    _lastPointerNavDir = direction;
    _lastPointerNavAt = now;
    _lastPointerPushGen = gen;
    return false;
  }

  Future<Object?> _handleNavigationCommand(MethodCall call) async {
    switch (call.method) {
      case 'back':
        if (_shouldSuppressCrossSource('back', fromChannel: true)) {
          return true;
        }
        return await widget.router.routerDelegate.popRoute();
      case 'forward':
        if (_shouldSuppressCrossSource('forward', fromChannel: true)) {
          return _history.canGoForward;
        }
        final handled = await _history.goForward();
        _lastChannelPushGen = _history.pushGeneration;
        return handled;
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
    switch (state) {
      case AppLifecycleState.resumed:
        HardwareKeyboard.instance.syncKeyboardState().ignore();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _releasePressedModifiers();
    }
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    switch (event.state) {
      case ViewFocusState.focused:
        HardwareKeyboard.instance.syncKeyboardState().ignore();
      case ViewFocusState.unfocused:
        _releasePressedModifiers();
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if ((event.buttons & kBackMouseButton) != 0) {
      _heldBackPointers.add(event.pointer);
      if (_shouldSuppressCrossSource('back', fromChannel: false)) return;
      unawaited(widget.router.routerDelegate.popRoute());
      return;
    }
    if ((event.buttons & kForwardMouseButton) != 0) {
      _heldForwardPointers.add(event.pointer);
      if (_shouldSuppressCrossSource('forward', fromChannel: false)) return;
      if (_history.canGoForward) {
        unawaited(_history.goForward());
        _lastPointerPushGen = _history.pushGeneration;
      }
    }
  }

  void _handlePointerRelease(int pointer) {
    if (_heldBackPointers.remove(pointer)) {
      _lastPointerNavDir = 'back';
      _lastPointerNavAt = DateTime.now();
      _lastPointerPushGen = _history.pushGeneration;
    }
    if (_heldForwardPointers.remove(pointer)) {
      _lastPointerNavDir = 'forward';
      _lastPointerNavAt = DateTime.now();
      _lastPointerPushGen = _history.pushGeneration;
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    final destinations = widget.destinations;
    final digitCount = destinations.length < _digitKeys.length
        ? destinations.length
        : _digitKeys.length;
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): const _BackIntent(
        unfocusEditing: true,
      ),
      if (isApple) ...{
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
            const _BackIntent(unfocusEditing: false),
        const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true):
            const _ForwardIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            const _SelectAllFeedIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            const _RefreshIntent(),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            const _OpenSettingsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true):
            const _ToggleRailIntent(),
        const SingleActivator(LogicalKeyboardKey.slash, meta: true):
            const _ShowShortcutsIntent(),
        for (var i = 0; i < digitCount; i++)
          SingleActivator(_digitKeys[i], meta: true): _GoHomeDestinationIntent(
            destinations[i],
          ),
      } else ...{
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            const _BackIntent(unfocusEditing: false),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            const _ForwardIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
            const _SelectAllFeedIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _RefreshIntent(),
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            const _OpenSettingsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            const _ToggleRailIntent(),
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            const _ShowShortcutsIntent(),
        for (var i = 0; i < digitCount; i++)
          SingleActivator(_digitKeys[i], control: true):
              _GoHomeDestinationIntent(destinations[i]),
      },
      const SingleActivator(LogicalKeyboardKey.slash): const _SearchIntent(),
      const SingleActivator(LogicalKeyboardKey.slash, shift: true):
          const _ShowShortcutsIntent(),
      const SingleActivator(LogicalKeyboardKey.question):
          const _ShowShortcutsIntent(),
      const SingleActivator(LogicalKeyboardKey.f5): const _RefreshIntent(),
    };

    final envPlatform = WindowEnvironmentOverride.maybeOf(
      context,
    )?.targetPlatform;
    final inheritedModality =
        InputModalityScope.maybeOf(context) ??
        (envPlatform != null ? defaultInputModalityFor(envPlatform) : null);

    return InputModalityScope(
      initialModality: inheritedModality,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        onPointerUp: (event) => _handlePointerRelease(event.pointer),
        onPointerCancel: (event) => _handlePointerRelease(event.pointer),
        child: Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              _BackIntent: _BackAction(widget.router),
              _ForwardIntent: _ForwardAction(widget.router),
              _SelectAllFeedIntent: _SelectAllFeedAction(widget.router),
              _SearchIntent: _SearchAction(widget.router),
              _RefreshIntent: _RefreshAction(widget.router),
              _OpenSettingsIntent: _OpenSettingsAction(widget.router),
              _ToggleRailIntent: _ToggleRailAction(
                widget.router,
                widget.onToggleRail,
              ),
              _GoHomeDestinationIntent: _GoHomeDestinationAction(widget.router),
              _ShowShortcutsIntent: _ShowShortcutsAction(widget.router),
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

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _ToggleRailIntent extends Intent {
  const _ToggleRailIntent();
}

class _GoHomeDestinationIntent extends Intent {
  const _GoHomeDestinationIntent(this.destination);

  final HomeDestination destination;
}

class _ForwardIntent extends Intent {
  const _ForwardIntent();
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}

class _SelectAllFeedIntent extends Intent {
  const _SelectAllFeedIntent();
}

class _BackAction extends Action<_BackIntent> {
  _BackAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_BackIntent intent) =>
      intent.unfocusEditing || !isTextEditingFocused();

  @override
  Object? invoke(_BackIntent intent) {
    if (intent.unfocusEditing && isTextEditingFocused()) {
      primaryFocus!.unfocus();
      return null;
    }
    if (intent.unfocusEditing &&
        !hasModalOrRootOverlay(router) &&
        FeedSelectionAnchor.clearActiveSelection()) {
      return null;
    }
    // False at the start page's root: nothing left to go back to.
    return router.routerDelegate.popRoute();
  }
}

class _ForwardAction extends Action<_ForwardIntent> {
  _ForwardAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_ForwardIntent intent) =>
      !isTextEditingFocused() &&
      ForwardHistoryStack.ofRouter(router).canGoForward;

  @override
  Object? invoke(_ForwardIntent intent) =>
      ForwardHistoryStack.ofRouter(router).goForward();
}

/// Whether a modal route, popup, or non-shell root overlay (such as the
/// fullscreen image viewer) currently covers the branch stack.
///
/// Pass [checkFocusRoute] = `false` when calling during a widget `build`
/// method: inspecting `ModalRoute.of(primaryFocus.context)` registers an
/// inherited dependency on another element and throws if focus still points at
/// a widget being deactivated in the same frame.
bool hasModalOrRootOverlay(GoRouter router, {bool checkFocusRoute = true}) {
  if (ForwardHistoryStack.ofRouter(router).hasOpenModal) return true;
  if (checkFocusRoute) {
    final focusContext = primaryFocus?.context;
    if (focusContext != null && focusContext.mounted) {
      final focusRoute = ModalRoute.of(focusContext);
      if (focusRoute is PopupRoute ||
          (focusRoute != null && focusRoute.settings is! Page)) {
        return true;
      }
    }
  }
  final config = router.routerDelegate.currentConfiguration;
  final path = config.uri.path;
  // Root-navigator pushes inside a stack (e.g. fullscreen image viewers) sit
  // above the branch navigator and must not be bypassed by shell shortcuts.
  final lastMatch = config.lastOrNull;
  if (lastMatch != null &&
      lastMatch.route.parentNavigatorKey ==
          router.routerDelegate.navigatorKey &&
      !_overlayRoots.contains(path)) {
    return true;
  }
  return false;
}

bool _canOpenSearchShortcut(GoRouter router) {
  if (hasModalOrRootOverlay(router)) return false;
  final path = liveRouterUri(router).path;
  if (path.endsWith('/search/input')) return false;
  return _stackRootOfPath(path) != null;
}

class _SelectAllFeedAction extends Action<_SelectAllFeedIntent> {
  _SelectAllFeedAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_SelectAllFeedIntent intent) =>
      !isTextEditingFocused() &&
      !hasModalOrRootOverlay(router) &&
      FeedSelectionAnchor.hasSelectableHost;

  @override
  Object? invoke(_SelectAllFeedIntent intent) {
    FeedSelectionAnchor.selectAllActive();
    return null;
  }
}

class _SearchAction extends Action<_SearchIntent> {
  _SearchAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_SearchIntent intent) =>
      !isTextEditingFocused() && _canOpenSearchShortcut(router);

  @override
  Object? invoke(_SearchIntent intent) {
    if (!_canOpenSearchShortcut(router)) return null;
    if (_SearchShortcutAnchorState.triggerActive()) return null;
    final path = liveRouterUri(router).path;
    final root = _stackRootOfPath(path);
    if (root == null) return null;
    final location = root == '/search' ? '/search/input' : '$root/search/input';
    unawaited(router.push<void>(location));
    return null;
  }
}

class _RefreshAction extends Action<_RefreshIntent> {
  _RefreshAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_RefreshIntent intent) => !isTextEditingFocused();

  @override
  Object? invoke(_RefreshIntent intent) {
    final focusContext =
        primaryFocus?.context ??
        router.routerDelegate.navigatorKey.currentContext;
    PullToRefresh.triggerActive(focusContext);
    return null;
  }
}

bool _canUseShellShortcut(GoRouter router) =>
    !hasModalOrRootOverlay(router) &&
    _stackRootOfPath(liveRouterUri(router).path) != null;

class _OpenSettingsAction extends Action<_OpenSettingsIntent> {
  _OpenSettingsAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_OpenSettingsIntent intent) =>
      !isTextEditingFocused() && _canUseShellShortcut(router);

  @override
  Object? invoke(_OpenSettingsIntent intent) {
    if (liveRouterUri(router).path != '/settings/all') {
      router.go('/settings/all');
    }
    return null;
  }
}

class _ToggleRailAction extends Action<_ToggleRailIntent> {
  _ToggleRailAction(this.router, this.onToggleRail);

  final GoRouter router;
  final VoidCallback? onToggleRail;

  @override
  bool isEnabled(_ToggleRailIntent intent) =>
      !isTextEditingFocused() && _canUseShellShortcut(router);

  @override
  Object? invoke(_ToggleRailIntent intent) {
    if (onToggleRail != null) {
      onToggleRail!.call();
      return null;
    }
    // On FormFactor.pc the rail is fixed expanded (onToggleRail == null), so
    // Ctrl/Cmd+B opens Bookmarks instead of being a dead binding.
    if (liveRouterUri(router).toString() != '/settings/me?tab=bookmarks') {
      router.go('/settings/me?tab=bookmarks');
    }
    return null;
  }
}

class _GoHomeDestinationAction extends Action<_GoHomeDestinationIntent> {
  _GoHomeDestinationAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_GoHomeDestinationIntent intent) =>
      !isTextEditingFocused() && _canUseShellShortcut(router);

  @override
  Object? invoke(_GoHomeDestinationIntent intent) {
    ForwardHistoryStack.ofRouter(
      router,
    ).selectHomeDestination(intent.destination);
    return null;
  }
}

class _ShowShortcutsIntent extends Intent {
  const _ShowShortcutsIntent();
}

class _ShowShortcutsAction extends Action<_ShowShortcutsIntent> {
  _ShowShortcutsAction(this.router);

  final GoRouter router;

  @override
  bool isEnabled(_ShowShortcutsIntent intent) =>
      !isTextEditingFocused() && !hasModalOrRootOverlay(router);

  @override
  Object? invoke(_ShowShortcutsIntent intent) {
    final nav = router.routerDelegate.navigatorKey.currentContext;
    if (nav != null) {
      unawaited(showKeyboardShortcutsSheet(nav));
    }
    return null;
  }
}
