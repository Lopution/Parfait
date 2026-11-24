import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/bookmark/bookmark_actions.dart';
import '../../../core/bookmark/bookmark_models.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../l10n/context.dart';
import '../../haptics/app_haptics.dart';
import '../../layout/app_breakpoints.dart';
import '../../layout/input_modality.dart';
import '../../motion/app_overlays.dart';
import '../../motion/motion_tokens.dart';
import '../../navigation/home_shell_metrics.dart';
import '../../navigation/route_facade.dart';
import '../../pull_to_refresh.dart';
import '../../theme/func_semantic_tokens.dart';
import '../../window/desktop_command_bar_scope.dart';
import '../app_snack_bar.dart';
import '../errors/error_details.dart';
import '../smooth_wheel_scroll.dart';
import '../../icons/app_icons.dart';
import '../../icons/ui_icons.dart';
import 'desktop_inspector_scope.dart';

bool _isHostOnScreen(BuildContext context) =>
    isRenderBoxVisibleOnScreen(context);

bool _hasShiftPressed() {
  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  return keys.contains(LogicalKeyboardKey.shiftLeft) ||
      keys.contains(LogicalKeyboardKey.shiftRight);
}

bool _hasPrimaryModifierPressed(TargetPlatform platform) {
  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  if (platform == TargetPlatform.macOS || platform == TargetPlatform.iOS) {
    return keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }
  return keys.contains(LogicalKeyboardKey.controlLeft) ||
      keys.contains(LogicalKeyboardKey.controlRight);
}

/// Manages artwork multi-selection state for one `>= 600dp` feed grid.
class FeedSelectionController extends ChangeNotifier {
  List<IllustEntity> _items = const [];
  final Set<int> _selectedIds = <int>{};
  int? _anchorId;
  bool _enabled = false;
  bool _disposed = false;
  bool _pruneScheduled = false;

  bool get enabled => _enabled;

  bool get hasSelection => _enabled && _selectedIds.isNotEmpty;

  bool get isSelectionMode => hasSelection;

  int get selectedCount => _enabled ? _selectedIds.length : 0;

  bool isSelected(int id) => _enabled && _selectedIds.contains(id);

  List<IllustEntity> get selectedEntities {
    if (!_enabled || _selectedIds.isEmpty) return const [];
    return [
      for (final item in _items)
        if (_selectedIds.contains(item.id)) item,
    ];
  }

  /// Updates viewport-width gating (`>= AppBreakpoints.medium`) without
  /// triggering synchronous build-phase notifications unless clearing active
  /// selections.
  void syncEnabledFromLayout(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value && _selectedIds.isNotEmpty) {
      _selectedIds.clear();
      _anchorId = null;
      _scheduleNotify();
    }
  }

  /// Updates the current grid's item list and prunes IDs no longer present.
  void syncItems(List<IllustEntity> items) {
    _items = List.unmodifiable(items);
    if (_selectedIds.isEmpty) return;
    if (items.isEmpty) {
      _selectedIds.clear();
      _anchorId = null;
      _scheduleNotify();
      return;
    }
    final validIds = <int>{for (final item in items) item.id};
    final before = _selectedIds.length;
    _selectedIds.removeWhere((id) => !validIds.contains(id));
    if (_anchorId != null && !validIds.contains(_anchorId)) {
      _anchorId = _selectedIds.isEmpty ? null : _selectedIds.last;
    }
    if (_selectedIds.length != before) {
      _scheduleNotify();
    }
  }

  /// Toggles [id] in the active selection.
  void toggle(int id) {
    if (!_enabled) return;
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
      if (_anchorId == id) {
        _anchorId = _selectedIds.isEmpty ? null : _selectedIds.last;
      }
    } else {
      _selectedIds.add(id);
      _anchorId = id;
    }
    AppHaptics.select();
    notifyListeners();
  }

  /// Selects an inclusive range between the previous anchor and [id].
  void selectRangeTo(int id) {
    if (!_enabled) return;
    final targetIndex = _items.indexWhere((item) => item.id == id);
    final anchorIndex = _anchorId == null
        ? -1
        : _items.indexWhere((item) => item.id == _anchorId);
    if (targetIndex < 0 || anchorIndex < 0) {
      _selectedIds.add(id);
      _anchorId = id;
    } else {
      final start = math.min(anchorIndex, targetIndex);
      final end = math.max(anchorIndex, targetIndex);
      for (var i = start; i <= end; i++) {
        _selectedIds.add(_items[i].id);
      }
    }
    AppHaptics.select();
    notifyListeners();
  }

  /// Selects every loaded artwork currently synced into the grid.
  void selectAll() {
    if (!_enabled || _items.isEmpty) return;
    var changed = false;
    for (final item in _items) {
      if (_selectedIds.add(item.id)) {
        changed = true;
      }
    }
    _anchorId ??= _items.first.id;
    if (changed) {
      AppHaptics.select();
      notifyListeners();
    }
  }

  /// Clears all selected items.
  void clearSelection() {
    if (_selectedIds.isEmpty && _anchorId == null) return;
    _selectedIds.clear();
    _anchorId = null;
    AppHaptics.select();
    notifyListeners();
  }

  /// Handles a primary card tap/activation inside [IllustCard]; returns `true`
  /// when consumed by multi-selection (Ctrl/Cmd+Click, Shift+Click, or active
  /// selection mode) so detail navigation is skipped.
  bool handleCardPrimaryTap(int id, TargetPlatform platform) {
    if (!_enabled) return false;
    if (_hasShiftPressed()) {
      selectRangeTo(id);
      return true;
    }
    if (_hasPrimaryModifierPressed(platform) || hasSelection) {
      toggle(id);
      return true;
    }
    return false;
  }

  void _scheduleNotify() {
    if (_pruneScheduled || _disposed) return;
    _pruneScheduled = true;
    scheduleMicrotask(() {
      _pruneScheduled = false;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Non-subscribing scope exposing the nearest [FeedSelectionController].
class FeedSelectionScope extends InheritedWidget {
  const FeedSelectionScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final FeedSelectionController controller;

  static FeedSelectionController? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<FeedSelectionScope>();
    return element == null
        ? null
        : (element.widget as FeedSelectionScope).controller;
  }

  @override
  bool updateShouldNotify(FeedSelectionScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Whether the card's top-start corner currently hosts the multi-select
/// checkbox (`>= 600dp` hover or active selection mode), so badges at that
/// corner shift aside instead of stacking underneath it.
class FeedSelectionCornerScope extends InheritedWidget {
  const FeedSelectionCornerScope({
    super.key,
    required this.occupied,
    required super.child,
  });

  final bool occupied;

  static bool topStartOccupiedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FeedSelectionCornerScope>()
          ?.occupied ??
      false;

  @override
  bool updateShouldNotify(FeedSelectionCornerScope oldWidget) =>
      occupied != oldWidget.occupied;
}

/// Global anchor lookup so `KeyboardBack` can route `Escape` (clear selection)
/// and `Ctrl/Cmd+A` (select all) to the visible on-screen feed even when a
/// mouse click did not focus an element inside the feed subtree.
abstract final class FeedSelectionAnchor {
  static final List<_SelectableFeedHostState> _hosts = [];

  static void _attach(_SelectableFeedHostState state) => _hosts.add(state);

  static void _detach(_SelectableFeedHostState state) => _hosts.remove(state);

  /// Clears selection on the top-most visible feed with active selections.
  static bool clearActiveSelection() {
    for (var i = _hosts.length - 1; i >= 0; i--) {
      final host = _hosts[i];
      if (!host.mounted || !_isHostOnScreen(host.context)) continue;
      if (host._controller.hasSelection) {
        host._controller.clearSelection();
        return true;
      }
    }
    return false;
  }

  /// Whether any on-screen host is enabled (`>= 600dp`) and has synced items.
  static bool get hasSelectableHost {
    for (var i = _hosts.length - 1; i >= 0; i--) {
      final host = _hosts[i];
      if (!host.mounted || !_isHostOnScreen(host.context)) continue;
      if (host._controller.enabled && host._controller._items.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Selects all artworks in the top-most visible enabled feed.
  static bool selectAllActive() {
    for (var i = _hosts.length - 1; i >= 0; i--) {
      final host = _hosts[i];
      if (!host.mounted || !_isHostOnScreen(host.context)) continue;
      if (host._controller.enabled && host._controller._items.isNotEmpty) {
        host._controller.selectAll();
        return true;
      }
    }
    return false;
  }
}

/// Hosts `>= 600dp` multi-selection state, `Ctrl/Cmd+A` + `Escape` fallback
/// shortcuts, and the contextual [FeedBatchActionBar] (inline top strip on
/// pointer desktop, thumb-reachable bottom pill on touch tablets).
class SelectableFeedHost extends StatefulWidget {
  const SelectableFeedHost({super.key, required this.child});

  final Widget child;

  @override
  State<SelectableFeedHost> createState() => _SelectableFeedHostState();
}

class _SelectableFeedHostState extends State<SelectableFeedHost> {
  final _controller = FeedSelectionController();
  final _childKey = GlobalKey();
  var _hadSelection = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSelectionChanged);
    FeedSelectionAnchor._attach(this);
  }

  void _onSelectionChanged() {
    final hasSelection = _controller.hasSelection;
    if (hasSelection && !_hadSelection && mounted) {
      DesktopInspectorScope.maybeOf(context)?.close();
    }
    _hadSelection = hasSelection;
  }

  @override
  void dispose() {
    FeedSelectionAnchor._detach(this);
    _controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    return LayoutBuilder(
      builder: (context, constraints) {
        _controller.syncEnabledFromLayout(
          constraints.maxWidth >= AppBreakpoints.medium,
        );
        final useTopInlineBar =
            (DesktopCommandBarScope.isActiveOf(context) ||
                usePointerOverlay(context)) &&
            constraints.hasBoundedHeight;
        final feedChild = KeyedSubtree(key: _childKey, child: widget.child);
        return FeedSelectionScope(
          controller: _controller,
          child: Shortcuts(
            shortcuts: <ShortcutActivator, Intent>{
              if (isApple)
                const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
                    const _FeedSelectAllIntent()
              else
                const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                    const _FeedSelectAllIntent(),
              const SingleActivator(LogicalKeyboardKey.escape):
                  const _FeedClearSelectionIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _FeedSelectAllIntent: _FeedSelectAllAction(_controller),
                _FeedClearSelectionIntent: _FeedClearSelectionAction(
                  _controller,
                ),
              },
              child: useTopInlineBar
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FeedBatchActionBar(
                          controller: _controller,
                          inlineTop: true,
                        ),
                        Expanded(child: feedChild),
                      ],
                    )
                  : Stack(
                      fit: StackFit.passthrough,
                      children: [
                        feedChild,
                        PositionedDirectional(
                          start: FuncSpacing.lg,
                          end: FuncSpacing.lg,
                          bottom:
                              math.max(
                                MediaQuery.paddingOf(context).bottom,
                                HomeShellChrome.maybeOf(
                                      context,
                                    )?.bottomBarExtent ??
                                    0,
                              ) +
                              FuncSpacing.lg,
                          child: Center(
                            child: FeedBatchActionBar(controller: _controller),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _FeedSelectAllIntent extends Intent {
  const _FeedSelectAllIntent();
}

class _FeedClearSelectionIntent extends Intent {
  const _FeedClearSelectionIntent();
}

class _FeedSelectAllAction extends Action<_FeedSelectAllIntent> {
  _FeedSelectAllAction(this.controller);

  final FeedSelectionController controller;

  @override
  bool isEnabled(_FeedSelectAllIntent intent) =>
      !isTextEditingFocused() &&
      controller.enabled &&
      controller._items.isNotEmpty;

  @override
  Object? invoke(_FeedSelectAllIntent intent) {
    controller.selectAll();
    return null;
  }
}

class _FeedClearSelectionAction extends Action<_FeedClearSelectionIntent> {
  _FeedClearSelectionAction(this.controller);

  final FeedSelectionController controller;

  @override
  bool isEnabled(_FeedClearSelectionIntent intent) => controller.hasSelection;

  @override
  Object? invoke(_FeedClearSelectionIntent intent) {
    controller.clearSelection();
    return null;
  }
}

/// Top sliver strip shown above `>= 600dp` grids once selection mode is
/// active, exposing count, Select All, and Clear Selection controls.
class FeedSelectionHeaderStrip extends StatelessWidget {
  const FeedSelectionHeaderStrip({super.key, required this.controller});

  final FeedSelectionController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.hasSelection) {
          return const SizedBox.shrink();
        }
        final l10n = context.l10n;
        final colors = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.sm,
            FuncSpacing.xs,
            FuncSpacing.sm,
            FuncSpacing.xs,
          ),
          child: Material(
            color: colors.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: FuncShape.control,
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FuncSpacing.md,
                vertical: FuncSpacing.xs,
              ),
              child: Row(
                children: [
                  Icon(UiIcons.checkCircle, size: 18, color: colors.primary),
                  const SizedBox(width: FuncSpacing.sm),
                  Expanded(
                    child: Text(
                      l10n.selectedCount(controller.selectedCount),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: controller.selectAll,
                    icon: const Icon(UiIcons.selectAll, size: 18),
                    label: Text(l10n.selectAll),
                  ),
                  const SizedBox(width: FuncSpacing.xs),
                  TextButton(
                    onPressed: controller.clearSelection,
                    child: Text(l10n.batchClearSelection),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Contextual batch action bar rendered by [SelectableFeedHost] while items
/// are selected (`Download Original`, `Public Bookmark`, `Private Bookmark`,
/// `Clear Selection`): an inline top toolbar on desktop pointer layouts and a
/// floating bottom pill on touch tablets.
class FeedBatchActionBar extends ConsumerWidget {
  const FeedBatchActionBar({
    super.key,
    required this.controller,
    this.inlineTop = false,
  });

  final FeedSelectionController controller;
  final bool inlineTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    final content = ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.hasSelection) {
          return const SizedBox.shrink();
        }
        final l10n = context.l10n;
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final tokens = theme.extension<FuncSemanticTokens>();
        final actions = <Widget>[
          TextButton.icon(
            onPressed: controller.selectAll,
            icon: const Icon(UiIcons.selectAll, size: 18),
            label: Text(l10n.selectAll),
          ),
          TextButton.icon(
            onPressed: () =>
                unawaited(_downloadSelected(context, ref, controller)),
            icon: const Icon(AppIcons.download, size: 18),
            label: Text(l10n.batchDownloadOriginal),
          ),
          TextButton.icon(
            onPressed: () => unawaited(
              _bookmarkSelected(
                context,
                ref,
                controller,
                BookmarkRestrict.public,
              ),
            ),
            icon: const Icon(AppIcons.heart, size: 18),
            label: Text(l10n.batchBookmarkPublic),
          ),
          TextButton.icon(
            onPressed: () => unawaited(
              _bookmarkSelected(
                context,
                ref,
                controller,
                BookmarkRestrict.private,
              ),
            ),
            icon: const Icon(AppIcons.lock, size: 18),
            label: Text(l10n.batchBookmarkPrivate),
          ),
          IconButton(
            onPressed: controller.clearSelection,
            icon: const Icon(UiIcons.close, size: 18),
            tooltip: l10n.batchClearSelection,
          ),
        ];

        if (inlineTop) {
          return Material(
            key: const Key('feed-batch-action-bar'),
            color: colors.surfaceContainerLow,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: tokens?.brandHairline ?? colors.outlineVariant,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FuncSpacing.lg - FuncSpacing.xxs,
                  vertical: FuncSpacing.xxs,
                ),
                child: Row(
                  children: [
                    Icon(UiIcons.checkCircle, size: 18, color: colors.primary),
                    const SizedBox(width: FuncSpacing.sm),
                    Text(
                      l10n.selectedCount(controller.selectedCount),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: FuncSpacing.md),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: actions,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Material(
          key: const Key('feed-batch-action-bar'),
          color: colors.surfaceContainerHigh,
          elevation: 6,
          shadowColor: colors.shadow.withValues(alpha: 0.25),
          shape: RoundedRectangleBorder(
            borderRadius: FuncShape.pill,
            side: BorderSide(color: colors.outlineVariant),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.md,
              vertical: FuncSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.selectedCount(controller.selectedCount),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(width: FuncSpacing.xs),
                ...actions,
              ],
            ),
          ),
        );
      },
    );
    if (!inlineTop) return content;
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  Future<void> _downloadSelected(
    BuildContext context,
    WidgetRef ref,
    FeedSelectionController controller,
  ) async {
    final entities = controller.selectedEntities;
    if (entities.isEmpty) return;
    final l10n = context.l10n;
    final showFailed = deferAppSnackBar(context, l10n.downloadSubmissionFailed);
    final downloader = ref.read(illustDownloadControllerProvider);
    controller.clearSelection();
    var anyNew = false;
    var submitted = 0;
    for (final entity in entities) {
      try {
        final submission = await downloader.downloadAll(entity);
        submitted += 1;
        if (submission.group != null) {
          anyNew = true;
        }
      } catch (_) {
        // Continue submitting remaining selected artworks.
      }
    }
    if (submitted == 0) {
      AppHaptics.error();
      showFailed();
      return;
    }
    if (context.mounted) {
      showDownloadSubmittedSnackBar(context, alreadyQueued: !anyNew);
    }
  }

  Future<void> _bookmarkSelected(
    BuildContext context,
    WidgetRef ref,
    FeedSelectionController controller,
    BookmarkRestrict restrict,
  ) async {
    final entities = controller.selectedEntities;
    if (entities.isEmpty) return;
    final l10n = context.l10n;
    final reportFailure = deferErrorSnackBar(
      context,
      action: l10n.bookmarkIllust,
    );
    final keys = [
      for (final entity in entities)
        BookmarkKey(BookmarkEntityType.illust, entity.id),
    ];
    controller.clearSelection();
    try {
      final count = await ref
          .read(bookmarkActionsProvider)
          .enqueueBatchAdd(keys, restrict);
      AppHaptics.success();
      if (context.mounted) {
        showAppSnackBar(context, l10n.batchBookmarkEnqueued(count));
      }
    } catch (error, stack) {
      AppHaptics.error();
      reportFailure(error, stack);
    }
  }
}

/// Wraps an [IllustCard] inside a [SelectableFeedHost] grid to draw the
/// selection highlight border and hover/active corner checkbox.
class FeedSelectableCardDecorator extends StatefulWidget {
  const FeedSelectableCardDecorator({
    super.key,
    required this.entityId,
    required this.child,
  });

  final int entityId;
  final Widget child;

  @override
  State<FeedSelectableCardDecorator> createState() =>
      _FeedSelectableCardDecoratorState();
}

class _FeedSelectableCardDecoratorState
    extends State<FeedSelectableCardDecorator> {
  var _hovered = false;

  void _onBadgeTap(FeedSelectionController controller) {
    if (_hasShiftPressed()) {
      controller.selectRangeTo(widget.entityId);
    } else {
      controller.toggle(widget.entityId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = FeedSelectionScope.maybeOf(context);
    if (controller == null) return widget.child;
    final modality =
        InputModalityScope.maybeOf(context) ??
        defaultInputModalityFor(Theme.of(context).platform);
    final colors = Theme.of(context).colorScheme;
    return ScrollAwareHoverRegion(
      onHover: (hovered) {
        if (_hovered != hovered) setState(() => _hovered = hovered);
      },
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, child) {
          final enabled = controller.enabled;
          final selected = controller.isSelected(widget.entityId);
          final showBadge =
              enabled &&
              (selected ||
                  controller.hasSelection ||
                  (_hovered && modality == InputModality.pointer));
          return Stack(
            clipBehavior: Clip.none,
            children: [
              FeedSelectionCornerScope(occupied: showBadge, child: child!),
              if (selected)
                Positioned(
                  left: -FuncSpacing.xs,
                  top: -FuncSpacing.xs,
                  right: -FuncSpacing.xs,
                  bottom: -(FuncSpacing.xs + FuncSpacing.xxs),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.06),
                        borderRadius: FuncShape.panel,
                        border: Border.all(color: colors.primary, width: 2),
                      ),
                    ),
                  ),
                ),
              if (showBadge)
                PositionedDirectional(
                  top: FuncSpacing.xs + FuncSpacing.xxs,
                  start: FuncSpacing.xs + FuncSpacing.xxs,
                  child: Semantics(
                    button: true,
                    selected: selected,
                    label: selected
                        ? context.l10n.batchDeselectWork
                        : context.l10n.batchSelectWork,
                    child: GestureDetector(
                      key: Key('feed-select-badge-${widget.entityId}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _onBadgeTap(controller),
                      child: Padding(
                        padding: const EdgeInsets.all(FuncSpacing.xxs),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? colors.primary
                                : colors.surface.withValues(alpha: 0.85),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(FuncSpacing.xxs),
                            child: Icon(
                              selected
                                  ? UiIcons.checkCircle
                                  : UiIcons.circleUnchecked,
                              size: 20,
                              color: selected
                                  ? colors.onPrimary
                                  : colors.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}
