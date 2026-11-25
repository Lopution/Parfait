import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../navigation/keyboard_back.dart';
import 'desktop_workspace_tabs.dart';

/// Tracks open desktop side-inspector panels (`DesktopInspectableGallery`) so
/// layered `Cmd+W` / `Ctrl+W` can dismiss an active inspector before closing a
/// secondary tab or window.
class DesktopInspectorDismissRegistry {
  DesktopInspectorDismissRegistry._();

  static final List<({bool Function() dismiss, bool Function() isActive})>
  _entries = [];

  static bool _alwaysActive() => true;

  static void register(bool Function() dismiss, {bool Function()? isActive}) {
    _entries.removeWhere((entry) => entry.dismiss == dismiss);
    _entries.add((dismiss: dismiss, isActive: isActive ?? _alwaysActive));
  }

  static void unregister(bool Function() dismiss) {
    _entries.removeWhere((entry) => entry.dismiss == dismiss);
  }

  static bool get hasActive => _entries.any((entry) => entry.isActive());

  static bool dismissActive() {
    for (var i = _entries.length - 1; i >= 0; i--) {
      final entry = _entries[i];
      if (!entry.isActive()) continue;
      if (entry.dismiss()) return true;
    }
    return false;
  }
}

/// Whether a layered close action (`Cmd+W` / `Ctrl+W`) would dismiss an
/// overlay, inspector, or secondary tab rather than the host window itself.
bool canDismissDesktopOverlayOrTab(
  GoRouter router, {
  bool checkFocusRoute = true,
}) {
  final tabs = DesktopWorkspaceTabsController.active;
  if (tabs != null && tabs.hasSecondaryModalOverlay) return true;
  if (hasModalOrRootOverlay(router, checkFocusRoute: checkFocusRoute)) {
    return true;
  }
  if (DesktopInspectorDismissRegistry.hasActive) return true;
  if (tabs != null && tabs.isOnSecondaryTab) return true;
  return false;
}

/// Layered desktop close dispatcher for `Cmd+W` (macOS) and `Ctrl+W`
/// (Windows/Linux):
/// 1. Active modal/popup/viewer/detail overlay on the active navigator or root
///    router.
/// 2. Active desktop side inspector (`DesktopInspectableGallery`).
/// 3. Active secondary workspace tab (returns to previous/root tab).
/// 4. On macOS only, invokes [onCloseWindow]. On Windows/Linux, no-op on the
///    last root tab.
bool dispatchLayeredDesktopClose({
  required GoRouter router,
  required bool isMacOS,
  VoidCallback? onCloseWindow,
}) {
  final tabs = DesktopWorkspaceTabsController.active;
  if (tabs != null && tabs.hasSecondaryModalOverlay) {
    unawaited(tabs.popActiveSecondary());
    return true;
  }
  if (hasModalOrRootOverlay(router)) {
    unawaited(router.routerDelegate.popRoute());
    return true;
  }
  if (DesktopInspectorDismissRegistry.dismissActive()) {
    return true;
  }
  if (tabs != null && tabs.closeActiveSecondaryTab()) {
    return true;
  }
  if (isMacOS && onCloseWindow != null) {
    onCloseWindow();
    return true;
  }
  return false;
}
