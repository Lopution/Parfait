import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../../haptics/app_haptics.dart';
import '../../layout/app_breakpoints.dart';
import '../../navigation/home_shell_metrics.dart';
import '../../theme/func_semantic_tokens.dart';
import '../../window/desktop_command_bar_scope.dart';
import '../app_menu_button.dart';
import '../settings/persist_settings.dart';
import 'desktop_inspector_scope.dart';
import '../../icons/app_icons.dart';
import '../../icons/ui_icons.dart';

/// Shared desktop gallery header controls (**NAV-17**): compact `"current ▾"`
/// menu buttons for desktop detail presentation (`DesktopDetailMode`) and
/// grid density (`FeedDensity`). Automatically collapses outside desktop mode,
/// below the corresponding width thresholds, or when [visible] is false (e.g.
/// on non-illust tabs such as novels or users).
class DesktopGalleryControls extends ConsumerWidget {
  const DesktopGalleryControls({super.key, this.visible = true});

  final bool visible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!visible || !DesktopCommandBarScope.isActiveOf(context)) {
      return const SizedBox.shrink();
    }
    final width = HomeShellChrome.contentSizeOf(context).width;
    final showDensity = width >= AppBreakpoints.medium;
    final showDetailMode = width >= desktopInspectorHostMinWidth;
    if (!showDensity && !showDetailMode) {
      return const SizedBox.shrink();
    }

    final l10n = context.l10n;
    final detailMode = ref.watch(desktopDetailModeProvider);
    final density = ref.watch(feedDensityProvider);

    String detailModeLabel(DesktopDetailMode mode) => switch (mode) {
      DesktopDetailMode.modal => l10n.desktopDetailModeModal,
      DesktopDetailMode.inspector => l10n.desktopDetailModeInspector,
    };

    IconData detailModeIcon(DesktopDetailMode mode) => switch (mode) {
      DesktopDetailMode.modal => AppIcons.externalLink,
      DesktopDetailMode.inspector => AppIcons.inspectorSidebar,
    };

    String densityLabel(FeedDensity value) => switch (value) {
      FeedDensity.comfortable => l10n.feedDensityComfortable,
      FeedDensity.standard => l10n.feedDensityStandard,
      FeedDensity.compact => l10n.feedDensityCompact,
    };

    IconData densityIcon(FeedDensity value) => switch (value) {
      FeedDensity.comfortable => AppIcons.layoutComfortable,
      FeedDensity.standard => AppIcons.layoutStandard,
      FeedDensity.compact => AppIcons.layoutCompact,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDetailMode)
            _GalleryMenuControl<DesktopDetailMode>(
              buttonKey: const Key('desktop-detail-mode-menu'),
              tooltip: l10n.desktopDetailMode,
              currentLabel: detailModeLabel(detailMode),
              icon: detailModeIcon(detailMode),
              value: detailMode,
              entries: [
                for (final mode in DesktopDetailMode.values)
                  AppMenuEntry(
                    value: mode,
                    label: detailModeLabel(mode),
                    icon: detailModeIcon(mode),
                    checked: mode == detailMode,
                  ),
              ],
              onSelected: (next) {
                unawaited(
                  persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setDesktopDetailMode(next),
                  ),
                );
              },
            ),
          if (showDetailMode && showDensity)
            const SizedBox(width: FuncSpacing.sm),
          if (showDensity)
            _GalleryMenuControl<FeedDensity>(
              buttonKey: const Key('feed-density-menu'),
              tooltip: l10n.feedDensity,
              currentLabel: densityLabel(density),
              icon: densityIcon(density),
              value: density,
              entries: [
                for (final item in FeedDensity.values)
                  AppMenuEntry(
                    value: item,
                    label: densityLabel(item),
                    icon: densityIcon(item),
                    checked: item == density,
                  ),
              ],
              onSelected: (next) {
                unawaited(
                  persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setFeedDensity(next),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _GalleryMenuControl<T> extends StatelessWidget {
  const _GalleryMenuControl({
    required this.buttonKey,
    required this.tooltip,
    required this.currentLabel,
    required this.icon,
    required this.value,
    required this.entries,
    required this.onSelected,
  });

  final Key buttonKey;
  final String tooltip;
  final String currentLabel;
  final IconData icon;
  final T value;
  final List<AppMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return AppMenuButton<T>(
      edge: AppMenuEdge.end,
      entries: entries,
      onSelected: (_, next) {
        if (next == value) return;
        AppHaptics.select();
        onSelected(next);
      },
      anchorBuilder: (context, toggle) => Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: OutlinedButton(
          key: buttonKey,
          onPressed: toggle,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsetsDirectional.only(
              start: FuncSpacing.md,
              end: FuncSpacing.sm,
            ),
            foregroundColor: Theme.of(context).colorScheme.onSurface,
          ),
          child: Semantics(
            label: '$tooltip: $currentLabel',
            excludeSemantics: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: FuncSpacing.xs),
                Flexible(
                  child: Text(
                    currentLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: FuncSpacing.xs),
                const Icon(UiIcons.dropdown, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
