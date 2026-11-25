import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/navigation/home_destination.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';
import '../layout/input_modality.dart';
import '../navigation/forward_history.dart';
import '../navigation/keyboard_back.dart';
import '../navigation/keyboard_shortcuts_sheet.dart';
import '../navigation/route_facade.dart';
import '../navigation/route_search_facade.dart';
import '../pull_to_refresh.dart';
import 'desktop_title_bar.dart';

const _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
];

const _preHomeExact = {'', '/', '/splash', '/user-agreement'};
const _preHomePrefixes = ['/welcome', '/login'];

bool _isPreHomeRouter(GoRouter router) {
  final path = liveRouterUri(router).path;
  if (_preHomeExact.contains(path)) return true;
  for (final prefix in _preHomePrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

BuildContext? _navContextOf(GoRouter router) {
  final overlayContext =
      router.routerDelegate.navigatorKey.currentState?.overlay?.context;
  if (overlayContext != null && overlayContext.mounted) return overlayContext;
  final navigatorContext = router.routerDelegate.navigatorKey.currentContext;
  if (navigatorContext != null && navigatorContext.mounted) {
    return navigatorContext;
  }
  return null;
}

String _destinationLabel(AppLocalizations l10n, HomeDestination destination) =>
    switch (destination) {
      HomeDestination.recommended => l10n.homeRecommended,
      HomeDestination.ranking => l10n.homeRanking,
      HomeDestination.newWorks => l10n.newTitle,
      HomeDestination.search => l10n.searchTitle,
      HomeDestination.me => l10n.homeMe,
    };

/// Builds the native macOS application menu bar structure. Standard AppKit
/// items (`About`, `Services`, `Hide`, `Show All`, `Quit`, `Bring All to
/// Front`) are included via [PlatformProvidedMenuItem] when [includeSystemQuit]
/// is enabled; the native `Edit` menu from `MainMenu.xib` is preserved by
/// `MacosDesktopWindowBridge.restoreEditMenu` after `PlatformMenuBar` commits.
@visibleForTesting
List<PlatformMenuItem> buildDesktopPlatformMenus({
  required AppLocalizations l10n,
  required GoRouter router,
  required bool isFullScreen,
  List<HomeDestination> destinations = HomeDestination.values,
  VoidCallback? onToggleFullScreen,
  VoidCallback? onMinimize,
  VoidCallback? onZoom,
  VoidCallback? onCloseWindow,
  bool includeSystemQuit = false,
}) {
  final history = ForwardHistoryStack.ofRouter(router);
  final preHome = _isPreHomeRouter(router);
  final blocked =
      preHome || hasModalOrRootOverlay(router, checkFocusRoute: false);
  VoidCallback? guard(VoidCallback action) => blocked
      ? null
      : () {
          if (_isPreHomeRouter(router) ||
              hasModalOrRootOverlay(router) ||
              isTextEditingFocused()) {
            return;
          }
          action();
        };
  bool hasSystemItem(PlatformProvidedMenuItemType type) =>
      includeSystemQuit && PlatformProvidedMenuItem.hasMenu(type);

  return [
    PlatformMenu(
      label: 'Parfait',
      menus: [
        if (hasSystemItem(PlatformProvidedMenuItemType.about))
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
            ],
          ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.menuPreferences,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: guard(() {
                if (liveRouterUri(router).path != '/settings/all') {
                  router.go('/settings/all');
                }
              }),
            ),
          ],
        ),
        if (hasSystemItem(PlatformProvidedMenuItemType.servicesSubmenu))
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.servicesSubmenu,
              ),
            ],
          ),
        if (hasSystemItem(PlatformProvidedMenuItemType.hide) ||
            hasSystemItem(PlatformProvidedMenuItemType.hideOtherApplications) ||
            hasSystemItem(PlatformProvidedMenuItemType.showAllApplications))
          PlatformMenuItemGroup(
            members: [
              if (hasSystemItem(PlatformProvidedMenuItemType.hide))
                const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hide,
                ),
              if (hasSystemItem(
                PlatformProvidedMenuItemType.hideOtherApplications,
              ))
                const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications,
                ),
              if (hasSystemItem(
                PlatformProvidedMenuItemType.showAllApplications,
              ))
                const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications,
                ),
            ],
          ),
        if (includeSystemQuit)
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
            ],
          ),
      ],
    ),
    PlatformMenu(
      label: l10n.menuFile,
      menus: [
        PlatformMenuItem(
          label: l10n.searchTitle,
          shortcut: const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
          onSelected: guard(() {
            if (SearchShortcutAnchor.triggerActive()) return;
            final nav = _navContextOf(router);
            if (nav != null) unawaited(openSearchInput(nav));
          }),
        ),
        PlatformMenuItem(
          label: l10n.searchReverseImage,
          onSelected: guard(() {
            final nav = _navContextOf(router);
            if (nav != null) unawaited(openReverseImageSearch(nav));
          }),
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.refresh,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyR,
                meta: true,
              ),
              onSelected: guard(
                () => PullToRefresh.triggerActive(_navContextOf(router)),
              ),
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.windowClose,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
              ),
              onSelected:
                  onCloseWindow == null &&
                      !hasModalOrRootOverlay(router, checkFocusRoute: false)
                  ? null
                  : () {
                      if (hasModalOrRootOverlay(
                        router,
                        checkFocusRoute: false,
                      )) {
                        unawaited(router.routerDelegate.popRoute());
                        return;
                      }
                      onCloseWindow?.call();
                    },
            ),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: l10n.menuNavigate,
      menus: [
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.navBack,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.bracketLeft,
                meta: true,
              ),
              onSelected: history.canGoBack
                  ? () {
                      if (isTextEditingFocused()) return;
                      unawaited(history.goBack());
                    }
                  : null,
            ),
            PlatformMenuItem(
              label: l10n.navForward,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.bracketRight,
                meta: true,
              ),
              onSelected: history.canGoForward
                  ? () {
                      if (isTextEditingFocused()) return;
                      unawaited(history.goForward());
                    }
                  : null,
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            for (
              var i = 0;
              i < destinations.length && i < _digitKeys.length;
              i++
            )
              PlatformMenuItem(
                label: _destinationLabel(l10n, destinations[i]),
                shortcut: SingleActivator(_digitKeys[i], meta: true),
                onSelected: guard(
                  () => history.selectHomeDestination(destinations[i]),
                ),
              ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.railBookmarks,
              onSelected: guard(() => router.go('/settings/me?tab=bookmarks')),
            ),
            PlatformMenuItem(
              label: l10n.railDownloads,
              onSelected: guard(() => router.go('/settings/downloads')),
            ),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: l10n.menuView,
      menus: [
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: isFullScreen
                  ? l10n.menuExitFullScreen
                  : l10n.menuEnterFullScreen,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
                meta: true,
              ),
              onSelected: onToggleFullScreen,
            ),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: l10n.menuWindow,
      menus: [
        PlatformMenuItem(
          label: l10n.windowMinimize,
          shortcut: const SingleActivator(LogicalKeyboardKey.keyM, meta: true),
          onSelected: onMinimize,
        ),
        PlatformMenuItem(label: l10n.windowMaximize, onSelected: onZoom),
        if (hasSystemItem(PlatformProvidedMenuItemType.arrangeWindowsInFront))
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
              ),
            ],
          ),
      ],
    ),
    PlatformMenu(
      label: l10n.menuHelp,
      menus: [
        PlatformMenuItem(
          label: l10n.keyboardShortcutsTitle,
          shortcut: const SingleActivator(LogicalKeyboardKey.slash, meta: true),
          onSelected: guard(() {
            final nav = _navContextOf(router);
            if (nav != null) unawaited(showKeyboardShortcutsSheet(nav));
          }),
        ),
      ],
    ),
  ];
}

/// Hosts the macOS native menu bar via [PlatformMenuBar] on real macOS builds
/// (or when [forcePlatformMenuBar] is enabled in tests).
class DesktopMenuBar extends StatefulWidget {
  const DesktopMenuBar({
    super.key,
    required this.settings,
    required this.router,
    this.destinations = HomeDestination.values,
    required this.child,
    this.forcePlatformMenuBar = false,
  });

  final AppSettings settings;
  final GoRouter router;
  final List<HomeDestination> destinations;
  final Widget child;
  final bool forcePlatformMenuBar;

  @override
  State<DesktopMenuBar> createState() => _DesktopMenuBarState();
}

class _DesktopMenuBarState extends State<DesktopMenuBar> {
  bool _rebuildPending = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onRouterChanged);
  }

  @override
  void didUpdateWidget(DesktopMenuBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routerDelegate.removeListener(_onRouterChanged);
      widget.router.routerDelegate.addListener(_onRouterChanged);
    }
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRouterChanged);
    super.dispose();
  }

  void _scheduleRebuild() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_rebuildPending) return;
      _rebuildPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _rebuildPending = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _onRouterChanged() => _scheduleRebuild();

  @override
  Widget build(BuildContext context) {
    final enabled =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            widget.forcePlatformMenuBar);
    if (!enabled) return widget.child;

    final l10n = context.l10n;
    final chrome = DesktopChromeMetrics.maybeOf(context);
    final actions =
        chrome?.actions ?? DesktopWindowScope.maybeOf(context)?.actions;
    final history = ForwardHistoryStack.ofRouter(widget.router);
    final includeSystemQuit =
        defaultTargetPlatform == TargetPlatform.macOS &&
        PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit);

    return ValueListenableBuilder<ForwardHistoryState>(
      valueListenable: history.stateListenable,
      builder: (context, _, _) {
        final onRestoreEditMenu = actions?.onRestoreEditMenu;
        if (defaultTargetPlatform == TargetPlatform.macOS &&
            onRestoreEditMenu != null) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) onRestoreEditMenu();
          });
        }
        return PlatformMenuBar(
          menus: buildDesktopPlatformMenus(
            l10n: l10n,
            router: widget.router,
            destinations: widget.destinations,
            isFullScreen: chrome?.isFullScreen ?? false,
            onToggleFullScreen: actions?.onToggleFullScreen,
            onMinimize: actions?.onMinimize,
            onZoom: actions?.onToggleMaximize,
            onCloseWindow: actions?.onClose,
            includeSystemQuit: includeSystemQuit,
          ),
          child: widget.child,
        );
      },
    );
  }
}
