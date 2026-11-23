import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/settings/app_settings.dart';
import '../../navigation/home_shell_metrics.dart';
import '../../window/desktop_command_bar_scope.dart';
import 'illust_pager_source.dart';

/// Minimum viewport width required to mount the desktop side inspector cleanly.
const double desktopInspectorMinWidth = 1040;

/// Minimum host content width needed so the feed retains >= 320dp alongside
/// the 420–520dp side inspector panel.
const double desktopInspectorHostMinWidth = 760;

/// Whether the current desktop surface is wide enough (in content width, after
/// subtracting any `ShellRail`) and configured to open artworks inside the
/// adjacent gallery inspector.
bool canUseDesktopInspector(
  BuildContext context,
  DesktopDetailMode detailMode,
) =>
    DesktopCommandBarScope.isActiveOf(context) &&
    HomeShellChrome.contentSizeOf(context).width >=
        desktopInspectorHostMinWidth &&
    detailMode == DesktopDetailMode.inspector;

/// Metadata captured from the feed card that launched the desktop inspector,
/// preserving exact hero origin and pager navigation when promoted to full stage.
class DesktopInspectorTarget {
  const DesktopInspectorTarget({
    required this.entity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.pagerSource,
  });

  final IllustEntity entity;
  final String heroScope;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;
  final IllustPagerSource? pagerSource;
}

/// Publishes the desktop inline gallery inspector controller so [IllustCard]
/// paints a crisp selection outline when inspected and routes primary taps into
/// the adjacent inspector panel instead of immediately pushing a modal route.
class DesktopInspectorScope extends InheritedWidget {
  const DesktopInspectorScope({
    super.key,
    required this.selectedId,
    required this.onInspect,
    this.onClose,
    this.enabled = true,
    required super.child,
  });

  final ValueListenable<int?> selectedId;
  final ValueChanged<DesktopInspectorTarget> onInspect;
  final VoidCallback? onClose;
  final bool enabled;

  /// Closes any open side inspector panel in this gallery host.
  void close() => onClose?.call();

  /// Non-subscribing lookup (for gesture callbacks or tests inspecting tree
  /// state). Returns null when the inspector mode is disabled.
  static DesktopInspectorScope? maybeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<DesktopInspectorScope>();
    if (element == null) return null;
    final scope = element.widget as DesktopInspectorScope;
    return scope.enabled ? scope : null;
  }

  /// Subscribing lookup used during widget build so cards rebuild immediately
  /// when desktop detail mode toggles between modal and side inspector.
  static DesktopInspectorScope? watchOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DesktopInspectorScope>();
    if (scope == null || !scope.enabled) return null;
    return scope;
  }

  @override
  bool updateShouldNotify(DesktopInspectorScope oldWidget) =>
      enabled != oldWidget.enabled ||
      !identical(selectedId, oldWidget.selectedId) ||
      onInspect != oldWidget.onInspect ||
      onClose != oldWidget.onClose;
}

/// Coordinates system back / Esc inside an embedded detail inspector so an
/// active sub-mode (page download selection or comment composer) dismisses
/// before its outer host closes the inspector pane.
class IllustEmbeddedBackController {
  bool Function()? handler;

  bool handleBack() => handler?.call() ?? false;
}

/// Factory that builds the desktop side detail inspector panel without
/// coupling feed widgets directly to `features/illust/detail/`.
typedef DesktopGalleryInspectorBuilder =
    Widget Function({
      required DesktopInspectorTarget target,
      required double panelWidth,
      required bool active,
      required IllustEmbeddedBackController backController,
      required VoidCallback onClose,
      required ValueChanged<IllustEntity> onOpenStage,
    });

DesktopGalleryInspectorBuilder? _desktopGalleryInspectorBuilder;

/// Whether a desktop gallery inspector builder has been registered.
bool get hasDesktopGalleryInspector => _desktopGalleryInspectorBuilder != null;

/// Registers the desktop gallery inspector builder once from router assembly.
void registerDesktopGalleryInspector(DesktopGalleryInspectorBuilder builder) {
  _desktopGalleryInspectorBuilder = builder;
}

/// Builds the registered desktop gallery inspector panel, or `null` when none
/// is registered (e.g. a narrow unit test without the full app router).
Widget? buildDesktopGalleryInspector({
  required DesktopInspectorTarget target,
  required double panelWidth,
  required bool active,
  required IllustEmbeddedBackController backController,
  required VoidCallback onClose,
  required ValueChanged<IllustEntity> onOpenStage,
}) {
  final builder = _desktopGalleryInspectorBuilder;
  if (builder == null) return null;
  return builder(
    target: target,
    panelWidth: panelWidth,
    active: active,
    backController: backController,
    onClose: onClose,
    onOpenStage: onOpenStage,
  );
}
