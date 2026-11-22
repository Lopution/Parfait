import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/navigation/home_destination.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';
import '../layout/form_factor.dart';
import '../navigation/forward_history.dart';
import '../navigation/keyboard_back.dart';
import '../navigation/route_facade.dart';
import '../navigation/route_search_facade.dart';
import '../pull_to_refresh.dart';
import '../widgets/settings/persist_settings.dart';
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

/// Builds the native macOS application menu bar structure without touching the
/// Edit menu, keeping AppKit text-editing shortcuts (`Cmd+C/V/X/A/Z`) native.
@visibleForTesting
List<PlatformMenuItem> buildDesktopPlatformMenus({
  required AppLocalizations l10n,
  required GoRouter router,
  required bool railExpanded,
  required bool isFullScreen,
  required VoidCallback onToggleRail,
  bool canToggleRail = true,
  VoidCallback? onToggleFullScreen,
  VoidCallback? onMinimize,
  VoidCallback? onZoom,
  bool includeSystemQuit = false,
}) {
  final history = ForwardHistoryStack.ofRouter(router);
  final preHome = _isPreHomeRouter(router);

  return [
    PlatformMenu(
      label: 'Parfait',
      menus: [
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.menuPreferences,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: preHome
                  ? null
                  : () {
                      if (liveRouterUri(router).path != '/settings/all') {
                        router.go('/settings/all');
                      }
                    },
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
          onSelected: preHome
              ? null
              : () {
                  if (SearchShortcutAnchor.triggerActive()) return;
                  final nav = _navContextOf(router);
                  if (nav != null) unawaited(openSearchInput(nav));
                },
        ),
        PlatformMenuItem(
          label: l10n.searchReverseImage,
          onSelected: preHome
              ? null
              : () {
                  final nav = _navContextOf(router);
                  if (nav != null) unawaited(openReverseImageSearch(nav));
                },
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.refresh,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyR,
                meta: true,
              ),
              onSelected: preHome
                  ? null
                  : () => PullToRefresh.triggerActive(_navContextOf(router)),
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
                  ? () => unawaited(history.goBack())
                  : null,
            ),
            PlatformMenuItem(
              label: l10n.navForward,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.bracketRight,
                meta: true,
              ),
              onSelected: history.canGoForward
                  ? () => unawaited(history.goForward())
                  : null,
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            for (var i = 0; i < HomeDestination.values.length; i++)
              PlatformMenuItem(
                label: _destinationLabel(l10n, HomeDestination.values[i]),
                shortcut: SingleActivator(_digitKeys[i], meta: true),
                onSelected: preHome
                    ? null
                    : () => router.go(HomeDestination.values[i].rootPath),
              ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: l10n.railBookmarks,
              onSelected: preHome
                  ? null
                  : () => router.go('/settings/me?tab=bookmarks'),
            ),
            PlatformMenuItem(
              label: l10n.railDownloads,
              onSelected: preHome
                  ? null
                  : () => router.go('/settings/downloads'),
            ),
          ],
        ),
      ],
    ),
    PlatformMenu(
      label: l10n.menuView,
      menus: [
        if (canToggleRail)
          PlatformMenuItem(
            label: railExpanded ? l10n.railCollapse : l10n.railExpand,
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyB,
              meta: true,
            ),
            onSelected: preHome ? null : onToggleRail,
          ),
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
      ],
    ),
  ];
}

/// Hosts the macOS native menu bar via [PlatformMenuBar] on real macOS builds
/// (or when [forcePlatformMenuBar] is enabled in tests).
class DesktopMenuBar extends ConsumerStatefulWidget {
  const DesktopMenuBar({
    super.key,
    required this.settings,
    required this.router,
    required this.child,
    this.forcePlatformMenuBar = false,
  });

  final AppSettings settings;
  final GoRouter router;
  final Widget child;
  final bool forcePlatformMenuBar;

  @override
  ConsumerState<DesktopMenuBar> createState() => _DesktopMenuBarState();
}

class _DesktopMenuBarState extends ConsumerState<DesktopMenuBar> {
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
    final railChoice =
        ref.watch(railExpandedProvider) ?? widget.settings.railExpanded;
    final size = MediaQuery.sizeOf(context);
    final form = FormFactor.of(context);
    final canToggleRail = form.canToggleRail(size.width, height: size.height);
    final railExpanded = form.railExpanded(
      size.width,
      height: size.height,
      choice: railChoice,
    );
    final history = ForwardHistoryStack.ofRouter(widget.router);
    final includeSystemQuit =
        defaultTargetPlatform == TargetPlatform.macOS &&
        PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit);

    return ValueListenableBuilder<ForwardHistoryState>(
      valueListenable: history.stateListenable,
      builder: (context, _, _) => PlatformMenuBar(
        menus: buildDesktopPlatformMenus(
          l10n: l10n,
          router: widget.router,
          railExpanded: railExpanded,
          canToggleRail: canToggleRail,
          isFullScreen: chrome?.isFullScreen ?? false,
          onToggleRail: () {
            final next = !railExpanded;
            final nav = _navContextOf(widget.router);
            if (nav != null) {
              unawaited(
                persistSettings(
                  nav,
                  () =>
                      ref.read(settingsProvider.notifier).setRailExpanded(next),
                ),
              );
            } else {
              unawaited(
                ref.read(settingsProvider.notifier).setRailExpanded(next),
              );
            }
          },
          onToggleFullScreen: actions?.onToggleFullScreen,
          onMinimize: actions?.onMinimize,
          onZoom: actions?.onToggleMaximize,
          includeSystemQuit: includeSystemQuit,
        ),
        child: widget.child,
      ),
    );
  }
}
