import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent, kMiddleMouseButton;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/entity/illust_entity.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/search/search_models.dart';
import '../../l10n/context.dart';
import '../icons/app_icons.dart';
import '../icons/ui_icons.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';

/// Height of [DesktopWorkspaceTabStrip] when 2 or more tabs are open.
const double kDesktopWorkspaceTabStripHeight = 36;

/// Typed destination opened inside a detached desktop workspace tab.
sealed class DesktopTabTarget {
  const DesktopTabTarget();

  String get title;
  IconData get icon;
  String get dedupeKey;
}

final class IllustTabTarget extends DesktopTabTarget {
  const IllustTabTarget(this.entity);

  final IllustEntity entity;

  @override
  String get title => entity.title.isNotEmpty ? entity.title : '#${entity.id}';

  @override
  IconData get icon => AppIcons.illust;

  @override
  String get dedupeKey => 'illust:${entity.id}';
}

final class NovelTabTarget extends DesktopTabTarget {
  const NovelTabTarget(this.entity);

  final NovelEntity entity;

  @override
  String get title => entity.title.isNotEmpty ? entity.title : '#${entity.id}';

  @override
  IconData get icon => AppIcons.novel;

  @override
  String get dedupeKey => 'novel:${entity.id}';
}

final class UserTabTarget extends DesktopTabTarget {
  const UserTabTarget({required this.userId, required this.name});

  final int userId;
  final String name;

  @override
  String get title => name.isNotEmpty ? name : 'User $userId';

  @override
  IconData get icon => AppIcons.user;

  @override
  String get dedupeKey => 'user:$userId';
}

final class SearchTabTarget extends DesktopTabTarget {
  const SearchTabTarget(this.query);

  final SearchQuery query;

  @override
  String get title => query.keyword;

  @override
  IconData get icon => AppIcons.search;

  @override
  String get dedupeKey => 'search:${query.cacheKey}';
}

typedef DesktopTabPageBuilder = WidgetBuilder Function(DesktopTabTarget target);

/// One detached secondary workspace tab hosted beside the permanent root
/// `StatefulNavigationShell` (tab 0) on desktop `FormFactor.pc`.
class DesktopWorkspaceTab {
  DesktopWorkspaceTab({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.dedupeKey,
  }) : navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'ws-tab-$id');

  final String id;
  final String title;
  final IconData icon;
  final WidgetBuilder builder;
  final String? dedupeKey;
  final GlobalKey<NavigatorState> navigatorKey;
}

/// Owns the desktop workspace tab list without recreating `GoRouter` (`NAV-02`).
///
/// Tab 0 is always the permanent `StatefulNavigationShell` root workspace;
/// indices `1..n` map to `secondaryTabs[index - 1]`.
class DesktopWorkspaceTabsController extends ChangeNotifier {
  DesktopWorkspaceTabsController({DesktopTabPageBuilder? pageBuilder})
    : _pageBuilder = pageBuilder;

  static DesktopWorkspaceTabsController? _active;

  /// Currently mounted desktop shell's tab controller, if any.
  static DesktopWorkspaceTabsController? get active => _active;

  final DesktopTabPageBuilder? _pageBuilder;
  final List<DesktopWorkspaceTab> _secondaryTabs = [];
  int _activeIndex = 0;
  int _nextId = 0;

  List<DesktopWorkspaceTab> get secondaryTabs =>
      List.unmodifiable(_secondaryTabs);

  int get tabCount => 1 + _secondaryTabs.length;

  bool get hasSecondaryTabs => _secondaryTabs.isNotEmpty;

  int get activeIndex => _activeIndex;

  bool get isOnSecondaryTab => _activeIndex > 0;

  DesktopWorkspaceTab? get activeSecondaryTab =>
      isOnSecondaryTab && _activeIndex <= _secondaryTabs.length
      ? _secondaryTabs[_activeIndex - 1]
      : null;

  bool get canActiveSecondaryPop =>
      activeSecondaryTab?.navigatorKey.currentState?.canPop() ?? false;

  BuildContext? get activeSecondaryContext =>
      activeSecondaryTab?.navigatorKey.currentContext;

  void attachAsActive() {
    _active = this;
  }

  void detachIfActive() {
    if (identical(_active, this)) _active = null;
  }

  DesktopWorkspaceTab? openTargetInBackground(DesktopTabTarget target) {
    final dedupeKey = target.dedupeKey;
    for (final existing in _secondaryTabs) {
      if (existing.dedupeKey == dedupeKey) return existing;
    }
    final builder = _pageBuilder?.call(target);
    if (builder == null) return null;
    return openBackgroundTab(
      title: target.title,
      icon: target.icon,
      builder: builder,
      dedupeKey: dedupeKey,
    );
  }

  /// Appends a background secondary tab without switching [activeIndex] or
  /// disturbing scroll positions in the current tab. Reuses an existing tab
  /// with the same [dedupeKey] if already open.
  DesktopWorkspaceTab openBackgroundTab({
    required String title,
    required IconData icon,
    required WidgetBuilder builder,
    String? dedupeKey,
  }) {
    if (dedupeKey != null) {
      for (final existing in _secondaryTabs) {
        if (existing.dedupeKey == dedupeKey) return existing;
      }
    }
    final tab = DesktopWorkspaceTab(
      id: 'tab_${++_nextId}',
      title: title,
      icon: icon,
      builder: builder,
      dedupeKey: dedupeKey,
    );
    _secondaryTabs.add(tab);
    notifyListeners();
    return tab;
  }

  void selectTab(int index) {
    final clamped = index.clamp(0, _secondaryTabs.length);
    if (clamped == _activeIndex) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _activeIndex = clamped;
    notifyListeners();
  }

  /// Cycles across `[0 .. secondaryTabs.length]` (wraps around).
  void cycleTab({int delta = 1}) {
    final total = tabCount;
    if (total <= 1) return;
    final next = (_activeIndex + delta) % total;
    selectTab(next < 0 ? next + total : next);
  }

  /// Closes the secondary tab at workspace [index] (`>= 1`). Tab 0 (root
  /// workspace) is permanent and cannot be closed.
  bool closeTabAt(int index) {
    if (index < 1 || index > _secondaryTabs.length) return false;
    final closingActive = _activeIndex == index;
    if (closingActive) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _secondaryTabs.removeAt(index - 1);
    if (closingActive) {
      _activeIndex = (index - 1).clamp(0, _secondaryTabs.length);
    } else if (_activeIndex > index) {
      _activeIndex -= 1;
    }
    notifyListeners();
    return true;
  }

  /// Closes the currently active secondary tab, returning `false` on tab 0.
  bool closeActiveSecondaryTab() =>
      isOnSecondaryTab ? closeTabAt(_activeIndex) : false;

  /// Pops one route inside the active secondary tab's navigator when possible.
  Future<bool> popActiveSecondary() async {
    final nav = activeSecondaryTab?.navigatorKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    return nav.maybePop();
  }

  /// Whether the active secondary tab currently has a modal/popup route above
  /// its root page.
  bool get hasSecondaryModalOverlay {
    final nav = activeSecondaryTab?.navigatorKey.currentState;
    if (nav == null) return false;
    var hasPopup = false;
    nav.popUntil((route) {
      if (route is PopupRoute || route.settings is! Page) {
        hasPopup = !route.isFirst;
      }
      return true;
    });
    return hasPopup;
  }

  @override
  void dispose() {
    detachIfActive();
    _secondaryTabs.clear();
    super.dispose();
  }
}

/// Publishes [DesktopWorkspaceTabsController] to desktop descendants.
/// Absent on mobile/touch shells (`FormFactor.phone` / `FormFactor.touch`).
class DesktopWorkspaceTabsScope
    extends InheritedNotifier<DesktopWorkspaceTabsController> {
  const DesktopWorkspaceTabsScope({
    super.key,
    required DesktopWorkspaceTabsController controller,
    required super.child,
  }) : super(notifier: controller);

  static DesktopWorkspaceTabsController? maybeOf(
    BuildContext context, {
    bool listen = true,
  }) {
    if (listen) {
      return context
          .dependOnInheritedWidgetOfExactType<DesktopWorkspaceTabsScope>()
          ?.notifier;
    }
    return context
        .getInheritedWidgetOfExactType<DesktopWorkspaceTabsScope>()
        ?.notifier;
  }
}

/// Auto-hidden warm-neutral desktop tab strip mounted directly under
/// `DesktopCommandBar`: collapses to `0dp` when only the root tab exists and
/// reveals a `36dp` wheel-scrollable strip once 2+ tabs are open.
class DesktopWorkspaceTabStrip extends StatefulWidget {
  const DesktopWorkspaceTabStrip({super.key, required this.controller});

  final DesktopWorkspaceTabsController controller;

  @override
  State<DesktopWorkspaceTabStrip> createState() =>
      _DesktopWorkspaceTabStripState();
}

class _DesktopWorkspaceTabStripState extends State<DesktopWorkspaceTabStrip> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrollController.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final pos = _scrollController.position;
    final next = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (next != pos.pixels) _scrollController.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final shown = widget.controller.hasSecondaryTabs;
        final duration = MotionTokens.resolve(context, MotionTokens.stateFade);
        return AnimatedContainer(
          key: const Key('desktop-workspace-tab-strip'),
          duration: duration,
          curve: MotionTokens.stateFadeCurve,
          height: shown ? kDesktopWorkspaceTabStripHeight : 0,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: shown ? _buildBar(context) : const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildBar(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final l10n = context.l10n;
    final controller = widget.controller;
    final secondary = controller.secondaryTabs;
    return Material(
      color: colors.surfaceContainerLow,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: ListView.separated(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.sm,
              vertical: FuncSpacing.xs,
            ),
            itemCount: 1 + secondary.length,
            separatorBuilder: (_, _) => const SizedBox(width: FuncSpacing.xs),
            itemBuilder: (context, index) {
              final isRoot = index == 0;
              final tab = isRoot ? null : secondary[index - 1];
              final active = controller.activeIndex == index;
              return _WorkspaceTabPill(
                key: Key(
                  isRoot
                      ? 'desktop-workspace-tab-root'
                      : 'desktop-workspace-tab-${tab!.id}',
                ),
                title: isRoot ? l10n.workspaceRootTab : tab!.title,
                icon: isRoot ? AppIcons.home : tab!.icon,
                active: active,
                closable: !isRoot,
                closeTooltip: l10n.closeTabTooltip,
                onSelect: () => controller.selectTab(index),
                onClose: isRoot ? null : () => controller.closeTabAt(index),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WorkspaceTabPill extends StatefulWidget {
  const _WorkspaceTabPill({
    super.key,
    required this.title,
    required this.icon,
    required this.active,
    required this.closable,
    required this.closeTooltip,
    required this.onSelect,
    this.onClose,
  });

  final String title;
  final IconData icon;
  final bool active;
  final bool closable;
  final String closeTooltip;
  final VoidCallback onSelect;
  final VoidCallback? onClose;

  @override
  State<_WorkspaceTabPill> createState() => _WorkspaceTabPillState();
}

class _WorkspaceTabPillState extends State<_WorkspaceTabPill> {
  var _hovered = false;
  int? _middlePointer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final bg = widget.active
        ? colors.surface
        : _hovered
        ? colors.surfaceContainerHighest
        : FuncTokens.transparent;
    final fg = widget.active ? colors.onSurface : colors.onSurfaceVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (event) {
          if (widget.closable && (event.buttons & kMiddleMouseButton) != 0) {
            _middlePointer = event.pointer;
          }
        },
        onPointerUp: (event) {
          if (_middlePointer == event.pointer) {
            _middlePointer = null;
            widget.onClose?.call();
          }
        },
        onPointerCancel: (event) {
          if (_middlePointer == event.pointer) _middlePointer = null;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220, minWidth: 80),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: bg,
                borderRadius: FuncShape.control,
                border: widget.active
                    ? Border.all(color: tokens.divider)
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 14, color: fg),
                    const SizedBox(width: FuncSpacing.xs),
                    Flexible(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: fg,
                          fontWeight: widget.active
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    if (widget.closable) ...[
                      const SizedBox(width: FuncSpacing.xs),
                      Tooltip(
                        message: widget.closeTooltip,
                        child: InkResponse(
                          key: Key('${widget.key}-close'),
                          onTap: widget.onClose,
                          radius: 12,
                          child: Padding(
                            padding: const EdgeInsets.all(FuncSpacing.xxs),
                            child: Icon(UiIcons.close, size: 12, color: fg),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hosts the permanent root workspace (tab 0) alongside detached secondary
/// `Navigator` tabs, freezing inactive tabs with [Offstage],
/// `TickerMode(enabled: false)`, and `HeroMode(enabled: false)`.
class DesktopWorkspaceTabHost extends StatelessWidget {
  const DesktopWorkspaceTabHost({
    super.key,
    required this.controller,
    required this.rootChild,
    this.router,
  });

  final DesktopWorkspaceTabsController controller;
  final Widget rootChild;
  final GoRouter? router;

  @override
  Widget build(BuildContext context) {
    final boundRouter = router;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final activeIndex = controller.activeIndex;
        final secondary = controller.secondaryTabs;
        return Stack(
          fit: StackFit.expand,
          children: [
            _FrozenTabSlot(active: activeIndex == 0, child: rootChild),
            for (var i = 0; i < secondary.length; i++)
              _FrozenTabSlot(
                key: ValueKey('ws-slot-${secondary[i].id}'),
                active: activeIndex == i + 1,
                child: _wrapRouter(
                  boundRouter,
                  Navigator(
                    key: secondary[i].navigatorKey,
                    onGenerateRoute: (_) =>
                        MaterialPageRoute<void>(builder: secondary[i].builder),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _wrapRouter(GoRouter? boundRouter, Widget child) => boundRouter == null
      ? child
      : InheritedGoRouter(goRouter: boundRouter, child: child);
}

class _FrozenTabSlot extends StatelessWidget {
  const _FrozenTabSlot({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !active,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: active,
        descendantsAreTraversable: active,
        child: TickerMode(
          enabled: active,
          child: HeroMode(enabled: active, child: child),
        ),
      ),
    );
  }
}
