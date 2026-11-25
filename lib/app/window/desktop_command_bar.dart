import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/account_store.dart';
import '../../core/platform/desktop_window_channel.dart';
import '../../core/search/search_models.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/context.dart';
import '../icons/app_icons.dart';
import '../icons/ui_icons.dart';
import '../motion/app_overlays.dart';
import '../navigation/forward_history.dart';
import '../navigation/keyboard_back.dart';
import '../navigation/route_facade.dart';
import '../navigation/route_query_codecs.dart';
import '../navigation/route_search_facade.dart';
import '../person_avatar.dart';
import '../pull_to_refresh.dart';
import '../theme/func_semantic_tokens.dart';
import 'desktop_command_bar_scope.dart';
import 'desktop_command_bar_widgets.dart';
import 'desktop_title_bar.dart';
import 'desktop_title_bar_region_publisher.dart';
import 'desktop_workspace_tabs.dart';

export 'desktop_command_bar_scope.dart';

const _preHomePrefixes = ['/welcome', '/login'];
const _preHomeExact = {'', '/', '/splash', '/user-agreement'};

/// Whether [path] is a pre-home onboarding/auth route where [DesktopCommandBar]
/// omits navigation buttons so the pushed page owns its own back button.
bool isDesktopPreHomePath(String path) {
  if (_preHomeExact.contains(path)) return true;
  for (final prefix in _preHomePrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

/// Persistent `48dp` desktop chrome strip rendered above route content on
/// Windows, macOS, and Linux.
class DesktopCommandBar extends ConsumerStatefulWidget {
  const DesktopCommandBar({
    super.key,
    required this.settings,
    required this.router,
  });

  final AppSettings settings;
  final GoRouter router;

  @override
  ConsumerState<DesktopCommandBar> createState() => _DesktopCommandBarState();
}

class _DesktopCommandBarState extends ConsumerState<DesktopCommandBar> {
  final GlobalKey _leftDragKey = GlobalKey();
  final GlobalKey _rightDragKey = GlobalKey();
  final GlobalKey _maximizeKey = GlobalKey();
  final GlobalKey _captionButtonsKey = GlobalKey();
  final GlobalKey _searchPillKey = GlobalKey();
  final GlobalKey _filterButtonKey = GlobalKey();
  final GlobalKey _accountButtonKey = GlobalKey();
  final Object _filterMenuGroup = Object();
  final Object _accountMenuGroup = Object();
  final DesktopTitleBarRegionPublisher _regionPublisher =
      DesktopTitleBarRegionPublisher();

  bool _rebuildPending = false;
  bool _searchOpening = false;
  bool _filterMenuOpen = false;
  bool _accountMenuOpen = false;

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onRouterChanged);
    DesktopCommandActionsAnchor.addListener(_onAnchorChanged);
  }

  @override
  void didUpdateWidget(DesktopCommandBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routerDelegate.removeListener(_onRouterChanged);
      widget.router.routerDelegate.addListener(_onRouterChanged);
    }
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRouterChanged);
    DesktopCommandActionsAnchor.removeListener(_onAnchorChanged);
    _regionPublisher.clear();
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

  void _onAnchorChanged() => _scheduleRebuild();

  BuildContext? _navContext() {
    final overlayContext = widget
        .router
        .routerDelegate
        .navigatorKey
        .currentState
        ?.overlay
        ?.context;
    if (overlayContext != null && overlayContext.mounted) return overlayContext;
    final navigatorContext =
        widget.router.routerDelegate.navigatorKey.currentContext;
    if (navigatorContext != null && navigatorContext.mounted) {
      return navigatorContext;
    }
    return null;
  }

  void _scheduleRegionPublish(
    DesktopWindowActions? actions,
    DesktopChromeMetrics? chrome,
  ) {
    if (actions == null || chrome == null) return;
    _regionPublisher.schedulePublish(
      actions,
      isMounted: () => mounted,
      resolve: () {
        final currentChrome = DesktopChromeMetrics.maybeOf(context);
        final currentActions =
            currentChrome?.actions ??
            DesktopWindowScope.maybeOf(context)?.actions;
        if (currentActions == null || currentChrome == null) return null;
        final regions = <DesktopTitleBarRegion>[];
        final ownsBar =
            !currentChrome.isFullScreen && !currentChrome.usesSystemTitleBar;
        if (ownsBar) {
          DesktopTitleBarRegionPublisher.addRegion(
            regions,
            _leftDragKey,
            'caption',
          );
          DesktopTitleBarRegionPublisher.addRegion(
            regions,
            _rightDragKey,
            'caption',
          );
          if (currentChrome.showCustomButtons) {
            DesktopTitleBarRegionPublisher.addRegion(
              regions,
              _maximizeKey,
              'maximize',
            );
            DesktopTitleBarRegionPublisher.addRegion(
              regions,
              _captionButtonsKey,
              'buttons',
            );
          }
        }
        return (
          actions: currentActions,
          regions: regions,
          titleBarHeight: ownsBar ? kDesktopCommandBarHeight : 0.0,
        );
      },
    );
  }

  Future<void> _openSearch(Uri currentUri) async {
    if (_searchOpening) return;
    final navContext = _navContext();
    if (navContext == null) return;
    _searchOpening = true;
    try {
      final activeQuery = searchResultsQueryFromUri(currentUri);
      final fullQuery = searchResultsFullQueryFromUri(currentUri);
      if (activeQuery != null) {
        await editSearchFromResults(
          navContext,
          anchor: () => globalRectOfKey(_searchPillKey),
          keyword: activeQuery.keyword,
          type: activeQuery.type,
          initialIllustFilters: fullQuery is IllustSearchQuery
              ? fullQuery.filters
              : null,
          initialNovelFilters: fullQuery is NovelSearchQuery
              ? fullQuery.filters
              : null,
        );
      } else {
        await openSearchInput(
          navContext,
          anchor: () => globalRectOfKey(_searchPillKey),
        );
      }
    } finally {
      _searchOpening = false;
    }
  }

  Future<void> _openAnchoredMenu({
    required GlobalKey anchorKey,
    required Object groupId,
    required double minWidth,
    required double maxWidth,
    required double maxHeight,
    required WidgetBuilder builder,
  }) async {
    final navContext = _navContext();
    if (navContext == null) return;
    await showAppAdaptivePopover<void>(
      context: navContext,
      anchorContext: anchorKey.currentContext,
      minWidth: minWidth,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      useRootNavigator: true,
      builder: (popoverContext) {
        final route = ModalRoute.of(popoverContext);
        return TapRegion(
          groupId: groupId,
          onTapOutside: (_) {
            if (route?.isCurrent ?? false) {
              Navigator.of(popoverContext).pop();
            }
          },
          child: SingleChildScrollView(
            primary: false,
            padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xs),
            child: builder(popoverContext),
          ),
        );
      },
    );
  }

  Future<void> _openFilterPopover() async {
    final navContext = _navContext();
    if (navContext == null) return;
    if (_filterMenuOpen) {
      await Navigator.of(navContext, rootNavigator: true).maybePop();
      return;
    }
    _filterMenuOpen = true;
    try {
      await _openAnchoredMenu(
        anchorKey: _filterButtonKey,
        groupId: _filterMenuGroup,
        minWidth: 240,
        maxWidth: 288,
        maxHeight: 240,
        builder: (_) =>
            DesktopCommandFilterPopover(fallbackSettings: widget.settings),
      );
    } finally {
      _filterMenuOpen = false;
    }
  }

  Future<void> _openAccountPopover() async {
    final navContext = _navContext();
    if (navContext == null) return;
    if (_accountMenuOpen) {
      await Navigator.of(navContext, rootNavigator: true).maybePop();
      return;
    }
    _accountMenuOpen = true;
    try {
      await _openAnchoredMenu(
        anchorKey: _accountButtonKey,
        groupId: _accountMenuGroup,
        minWidth: 260,
        maxWidth: 320,
        maxHeight: 360,
        builder: (_) => DesktopCommandAccountPopover(router: widget.router),
      );
    } finally {
      _accountMenuOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = context.l10n;
    final tokens = FuncSemanticTokens.of(context);
    final chrome = DesktopChromeMetrics.maybeOf(context);
    final actions =
        chrome?.actions ?? DesktopWindowScope.maybeOf(context)?.actions;
    final hostMetrics =
        chrome?.hostMetrics ?? DesktopWindowPlatformMetrics.fallback;
    _scheduleRegionPublish(actions, chrome);

    final uri = liveRouterUri(widget.router);
    final isPreHome = isDesktopPreHomePath(uri.path);
    final usesSystemTitleBar = chrome?.usesSystemTitleBar ?? false;
    if (usesSystemTitleBar && isPreHome) {
      return const SizedBox.shrink();
    }
    final barHeight = desktopCommandBarHeightFor(chrome);
    final windowSize = MediaQuery.sizeOf(context);
    final history = ForwardHistoryStack.ofRouter(widget.router);
    final leadingInset = chrome?.leadingInset ?? 0;
    final showSimulatedTrafficLights =
        chrome?.showSimulatedTrafficLights ?? false;
    final showCustomButtons = chrome?.showCustomButtons ?? false;

    final searchQuery = searchResultsQueryFromUri(uri);
    final keywordText = searchQuery?.keyword.trim() ?? '';
    final contextAction = isPreHome
        ? null
        : DesktopCommandActionsAnchor.activeAction();
    final currentAccount = ref.watch(accountStoreProvider).value?.current;
    final searchWidth = (windowSize.width * 0.27).clamp(210.0, 360.0);
    final showShortcutBadge = windowSize.width >= 680;
    final showBrandWordmark = windowSize.width >= 600;
    final showBrandPill = !usesSystemTitleBar && windowSize.width >= 500;
    final compactWindow = windowSize.width < 500;
    final leadingGap = compactWindow ? FuncSpacing.sm : FuncSpacing.md;
    final estimatedLeft =
        leadingInset +
        leadingGap +
        (showBrandPill ? (showBrandWordmark ? 110.0 : 42.0) : 0.0) +
        90.0;
    final estimatedRight =
        (contextAction != null ? 44.0 : 0.0) +
        68.0 +
        (showCustomButtons ? 146.0 : FuncSpacing.md);
    final freeMiddle = math.max(
      0.0,
      windowSize.width - estimatedLeft - estimatedRight - FuncSpacing.sm,
    );
    final reservedDrag = usesSystemTitleBar ? 0.0 : 48.0;
    final availableForSearch = math.max(0.0, freeMiddle - reservedDrag);
    final compactSearch = compactWindow || availableForSearch < 120.0;
    final effectiveSearchWidth = math.min(searchWidth, availableForSearch);

    const iconConstraints = BoxConstraints(minWidth: 30, minHeight: 30);
    const iconPadding = EdgeInsets.all(FuncSpacing.xs);

    Widget guardModal(bool blocked, Widget child) => AbsorbPointer(
      absorbing: blocked,
      child: ExcludeSemantics(excluding: blocked, child: child),
    );

    return Material(
      key: const Key('desktop-command-bar'),
      color: colors.surfaceContainerLow,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.brandHairline)),
        ),
        child: SizedBox(
          height: barHeight,
          child: ValueListenableBuilder<ForwardHistoryState>(
            valueListenable: history.stateListenable,
            builder: (context, historyState, _) {
              final hasBlockingModal = historyState.hasBlockingModal;
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (leadingInset > 0)
                        SizedBox(
                          width: leadingInset,
                          height: barHeight,
                          child: showSimulatedTrafficLights
                              ? SimulatedMacTrafficLights(height: barHeight)
                              : null,
                        ),
                      SizedBox(width: leadingGap),
                      if (!isPreHome)
                        guardModal(
                          hasBlockingModal,
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (showBrandPill) ...[
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: tokens.brandTintWeak,
                                    borderRadius: FuncShape.pill,
                                    border: Border.all(
                                      color: tokens.brandHairline,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: showBrandWordmark
                                          ? FuncSpacing.sm + FuncSpacing.xxs
                                          : FuncSpacing.sm,
                                      vertical: FuncSpacing.xs,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Image.asset(
                                          'assets/branding/parfait_icon.png',
                                          width: 15,
                                          height: 15,
                                          excludeFromSemantics: true,
                                        ),
                                        if (showBrandWordmark) ...[
                                          const SizedBox(width: FuncSpacing.xs),
                                          Text(
                                            'Parfait',
                                            style: theme.textTheme.labelMedium
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: -0.2,
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: FuncSpacing.sm),
                              ],
                              Builder(
                                builder: (barContext) {
                                  final tabs =
                                      DesktopWorkspaceTabsScope.maybeOf(
                                        barContext,
                                      );
                                  final onSecondary =
                                      tabs?.isOnSecondaryTab ?? false;
                                  final canBack = onSecondary
                                      ? tabs!.canActiveSecondaryPop
                                      : historyState.canGoBack;
                                  final canForward =
                                      !onSecondary && historyState.canGoForward;
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      desktopCommandIconButton(
                                        barContext,
                                        key: const Key('desktop-command-back'),
                                        constraints: iconConstraints,
                                        padding: iconPadding,
                                        iconSize: 17,
                                        tooltip: l10n.navBack,
                                        onPressed: !hasBlockingModal && canBack
                                            ? () => unawaited(
                                                onSecondary
                                                    ? tabs!.popActiveSecondary()
                                                    : history.goBack(),
                                              )
                                            : null,
                                        icon: const Icon(UiIcons.arrowBack),
                                      ),
                                      desktopCommandIconButton(
                                        barContext,
                                        key: const Key(
                                          'desktop-command-forward',
                                        ),
                                        constraints: iconConstraints,
                                        padding: iconPadding,
                                        iconSize: 17,
                                        tooltip: l10n.navForward,
                                        onPressed:
                                            !hasBlockingModal && canForward
                                            ? () =>
                                                  unawaited(history.goForward())
                                            : null,
                                        icon: const Icon(UiIcons.arrowForward),
                                      ),
                                      desktopCommandIconButton(
                                        barContext,
                                        key: const Key(
                                          'desktop-command-refresh',
                                        ),
                                        constraints: iconConstraints,
                                        padding: iconPadding,
                                        iconSize: 17,
                                        tooltip: l10n.refresh,
                                        onPressed: hasBlockingModal
                                            ? null
                                            : () => PullToRefresh.triggerActive(
                                                onSecondary
                                                    ? (tabs!.activeSecondaryContext ??
                                                          _navContext())
                                                    : _navContext(),
                                              ),
                                        icon: const Icon(UiIcons.refresh),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      if (usesSystemTitleBar)
                        const Spacer()
                      else
                        Expanded(
                          child: DesktopCommandDragSpacer(
                            key: _leftDragKey,
                            height: barHeight,
                            actions: actions,
                          ),
                        ),
                      if (!isPreHome)
                        guardModal(
                          hasBlockingModal,
                          compactSearch
                              ? SearchShortcutAnchor(
                                  onTrigger: () => unawaited(_openSearch(uri)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      KeyedSubtree(
                                        key: _searchPillKey,
                                        child: desktopCommandIconButton(
                                          context,
                                          key: const Key(
                                            'desktop-command-search-pill',
                                          ),
                                          constraints: iconConstraints,
                                          padding: iconPadding,
                                          iconSize: 17,
                                          tooltip: l10n.searchHint,
                                          onPressed: hasBlockingModal
                                              ? null
                                              : () =>
                                                    unawaited(_openSearch(uri)),
                                          icon: const Icon(AppIcons.search),
                                        ),
                                      ),
                                      desktopCommandIconButton(
                                        context,
                                        key: const Key(
                                          'desktop-command-reverse-search',
                                        ),
                                        constraints: iconConstraints,
                                        padding: iconPadding,
                                        iconSize: 16,
                                        tooltip: l10n.searchReverseImage,
                                        onPressed: hasBlockingModal
                                            ? null
                                            : () {
                                                final navContext =
                                                    _navContext();
                                                if (navContext != null) {
                                                  unawaited(
                                                    openReverseImageSearch(
                                                      navContext,
                                                    ),
                                                  );
                                                }
                                              },
                                        icon: const Icon(AppIcons.imageSearch),
                                      ),
                                    ],
                                  ),
                                )
                              : ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: effectiveSearchWidth,
                                  ),
                                  child: SizedBox(
                                    width: effectiveSearchWidth,
                                    child: SearchShortcutAnchor(
                                      onTrigger: () =>
                                          unawaited(_openSearch(uri)),
                                      child: DesktopCommandSearchPill(
                                        key: _searchPillKey,
                                        height: usesSystemTitleBar ? 30 : 32,
                                        hint: l10n.searchHint,
                                        keyword: keywordText,
                                        reverseTooltip: l10n.searchReverseImage,
                                        showShortcutBadge: showShortcutBadge,
                                        onTapPill: () =>
                                            unawaited(_openSearch(uri)),
                                        onTapReverse: () {
                                          final navContext = _navContext();
                                          if (navContext != null) {
                                            unawaited(
                                              openReverseImageSearch(
                                                navContext,
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      if (usesSystemTitleBar)
                        const Spacer()
                      else
                        Expanded(
                          child: DesktopCommandDragSpacer(
                            key: _rightDragKey,
                            height: barHeight,
                            actions: actions,
                          ),
                        ),
                      if (!isPreHome)
                        guardModal(
                          hasBlockingModal,
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (contextAction != null) ...[
                                contextAction,
                                const SizedBox(width: FuncSpacing.xxs),
                              ],
                              TapRegion(
                                groupId: _filterMenuGroup,
                                child: KeyedSubtree(
                                  key: _filterButtonKey,
                                  child: desktopCommandIconButton(
                                    context,
                                    key: const Key('desktop-command-filter'),
                                    constraints: iconConstraints,
                                    padding: iconPadding,
                                    iconSize: 18,
                                    tooltip: l10n.commandContentFilter,
                                    onPressed: hasBlockingModal
                                        ? null
                                        : () => unawaited(_openFilterPopover()),
                                    icon: const Icon(AppIcons.shield),
                                  ),
                                ),
                              ),
                              const SizedBox(width: FuncSpacing.xs),
                              TapRegion(
                                groupId: _accountMenuGroup,
                                child: KeyedSubtree(
                                  key: _accountButtonKey,
                                  child: Semantics(
                                    container: true,
                                    button: true,
                                    label: l10n.commandSwitchAccount,
                                    excludeSemantics: true,
                                    child: maybeWrapCommandTooltip(
                                      context,
                                      message: l10n.commandSwitchAccount,
                                      excludeFromSemantics: true,
                                      child: InkWell(
                                        key: const Key(
                                          'desktop-command-account',
                                        ),
                                        customBorder: const CircleBorder(),
                                        onTap: hasBlockingModal
                                            ? null
                                            : () => unawaited(
                                                _openAccountPopover(),
                                              ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(
                                            FuncSpacing.xxs,
                                          ),
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: colors.primary
                                                    .withValues(alpha: 0.48),
                                                width: 1.5,
                                              ),
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(
                                                FuncSpacing.xxs,
                                              ),
                                              child: PersonAvatar(
                                                imageUrl: currentAccount
                                                    ?.profileImageUrl,
                                                radius: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(
                        width: showCustomButtons ? 138.0 + 8.0 : FuncSpacing.md,
                      ),
                    ],
                  ),
                  if (hasBlockingModal)
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          key: Key('desktop-command-bar-modal-scrim'),
                          color: Colors.black54,
                        ),
                      ),
                    ),
                  if (showCustomButtons)
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: KeyedSubtree(
                        key: _captionButtonsKey,
                        child: DesktopWindowCaptionButtons(
                          height: barHeight,
                          isMaximized: chrome?.isMaximized ?? false,
                          isActive: chrome?.isActive ?? true,
                          nativeHoveredButton: hostMetrics.hoveredButton,
                          nativePressedButton: hostMetrics.pressedButton,
                          maximizeKey: _maximizeKey,
                          actions: actions,
                          brightnessListenable: null,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
