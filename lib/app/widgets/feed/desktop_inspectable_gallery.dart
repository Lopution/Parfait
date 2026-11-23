import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../motion/hero_transition.dart';
import '../../motion/motion_tokens.dart';
import '../../navigation/route_facade.dart';
import 'desktop_inspector_scope.dart';

/// Reusable desktop master-detail host: wraps any illust gallery [child] with
/// [DesktopInspectorScope], animates the `420–520dp` side detail inspector
/// open/closed alongside it when [DesktopDetailMode.inspector] is active, and
/// intercepts `Esc` / mouse back via [PopScope] before the outer shell pops or
/// switches branches.
class DesktopInspectableGallery extends ConsumerStatefulWidget {
  const DesktopInspectableGallery({
    super.key,
    required this.child,
    this.enabled = true,
    this.active = true,
    this.scopeKey,
  });

  final Widget child;

  /// Caller gate (for example, disabled while multi-select management is on).
  final bool enabled;

  /// Whether the active view currently renders illust/manga cards. Switching to
  /// non-illust tabs (`novel`, `user`) closes any open inspector automatically.
  final bool active;

  /// Optional view-context key (for example active sibling tab or ranking
  /// date). Changing [scopeKey] closes any open inspector automatically.
  final Object? scopeKey;

  @override
  ConsumerState<DesktopInspectableGallery> createState() =>
      _DesktopInspectableGalleryState();
}

class _DesktopInspectableGalleryState
    extends ConsumerState<DesktopInspectableGallery>
    with SingleTickerProviderStateMixin {
  final _selectedId = ValueNotifier<int?>(null);
  final _backController = IllustEmbeddedBackController();
  late final AnimationController _panelController = AnimationController(
    vsync: this,
    value: 0,
  );

  DesktopInspectorTarget? _selected;
  DesktopInspectorTarget? _rendered;
  bool _snapCloseScheduled = false;

  @override
  void didUpdateWidget(DesktopInspectableGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!widget.enabled ||
            !widget.active ||
            widget.scopeKey != oldWidget.scopeKey) &&
        (_selected != null || _rendered != null)) {
      _snapCloseSync();
    }
  }

  @override
  void dispose() {
    _panelController.dispose();
    _selectedId.dispose();
    super.dispose();
  }

  void _snapCloseSync() {
    _selected = null;
    _rendered = null;
    _selectedId.value = null;
    _panelController.value = 0;
  }

  void _scheduleSnapClose() {
    if (_snapCloseScheduled) return;
    _snapCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snapCloseScheduled = false;
      if (!mounted || (_selected == null && _rendered == null)) return;
      setState(_snapCloseSync);
    });
  }

  void _open(DesktopInspectorTarget target) {
    if (!mounted) return;
    setState(() {
      _selected = target;
      _rendered = target;
      _selectedId.value = target.entity.id;
    });
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    if (duration == Duration.zero || !TickerMode.valuesOf(context).enabled) {
      _panelController.value = 1;
      return;
    }
    unawaited(_panelController.animateTo(1, duration: duration, curve: curve));
  }

  void _close() {
    if (_selected == null) return;
    setState(() {
      _selected = null;
      _selectedId.value = null;
    });
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    if (duration == Duration.zero || !TickerMode.valuesOf(context).enabled) {
      setState(() {
        _rendered = null;
        _panelController.value = 0;
      });
      return;
    }
    unawaited(
      _panelController.animateBack(0, duration: duration, curve: curve).then((
        _,
      ) {
        if (!mounted || _selected != null) return;
        if (_panelController.isDismissed) {
          setState(() => _rendered = null);
        }
      }),
    );
  }

  void _openFullStage(
    DesktopInspectorTarget target,
    IllustEntity latestEntity,
  ) {
    if (target.heroImageUrl != null) {
      noteHeroCardOpened(
        context,
        illustHeroTag(target.heroScope, latestEntity.id),
      );
    }
    unawaited(
      openIllust(
        context,
        latestEntity.id,
        initialEntity: latestEntity,
        heroScope: target.heroScope,
        heroImageUrl: target.heroImageUrl,
        heroImageDecodeWidth: target.heroImageDecodeWidth,
        pagerSource: target.pagerSource,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DesktopDetailMode>(desktopDetailModeProvider, (_, mode) {
      if (mode != DesktopDetailMode.inspector &&
          (_selected != null || _rendered != null)) {
        setState(_snapCloseSync);
      }
    });
    final detailMode = ref.watch(desktopDetailModeProvider);
    final modeEnabled =
        hasDesktopGalleryInspector &&
        widget.enabled &&
        widget.active &&
        canUseDesktopInspector(context, detailMode);

    return LayoutBuilder(
      builder: (context, constraints) {
        final canInspect =
            modeEnabled && constraints.maxWidth >= desktopInspectorHostMinWidth;
        if (!canInspect && (_selected != null || _rendered != null)) {
          _scheduleSnapClose();
        }
        final inspectorWidth = (constraints.maxWidth * 0.40).clamp(
          420.0,
          520.0,
        );
        final tickerActive = TickerMode.valuesOf(context).enabled;
        final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
        final isPanelOpen = canInspect && _selected != null;

        final inspectorWidget = canInspect && _rendered != null
            ? buildDesktopGalleryInspector(
                target: _rendered!,
                panelWidth: inspectorWidth,
                active: isPanelOpen && tickerActive && routeCurrent,
                backController: _backController,
                onClose: _close,
                onOpenStage: (latest) => _openFullStage(_rendered!, latest),
              )
            : null;
        final panel = inspectorWidget == null
            ? null
            : AnimatedBuilder(
                animation: _panelController,
                child: HeroMode(
                  enabled: isPanelOpen && tickerActive,
                  child: SizedBox(
                    width: inspectorWidth,
                    child: inspectorWidget,
                  ),
                ),
                builder: (context, child) {
                  final progress = _panelController.value.clamp(0.0, 1.0);
                  return IgnorePointer(
                    ignoring: !isPanelOpen,
                    child: ClipRect(
                      child: Align(
                        alignment: AlignmentDirectional.topStart,
                        widthFactor: progress,
                        child: Opacity(opacity: progress, child: child),
                      ),
                    ),
                  );
                },
              );

        return PopScope(
          canPop: !isPanelOpen || !routeCurrent || !tickerActive,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_backController.handleBack()) return;
            _close();
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DesktopInspectorScope(
                  enabled: canInspect,
                  selectedId: _selectedId,
                  onInspect: _open,
                  onClose: _close,
                  child: widget.child,
                ),
              ),
              ?panel,
            ],
          ),
        );
      },
    );
  }
}
