import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/reveal.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/func_bottom_nav.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../core/navigation/home_destination.dart';
import '../../../core/settings/arrangement.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Which destinations sit on the bottom bar, in what order. Those on the
/// bar come first and move by their handle (screen readers get move
/// actions); a switch takes one off the bar or puts it back at the end.
class BottomBarSettingsPage extends ConsumerWidget {
  const BottomBarSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    if (state.value == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'bottomBarItems',
      );
    }
    return Scaffold(
      appBar: AppTopBar(title: Text(context.l10n.bottomBarItems)),
      body: settingsNarrowBody(const _BottomBarEditor()),
    );
  }
}

class _BottomBarEditor extends ConsumerStatefulWidget {
  const _BottomBarEditor();

  @override
  ConsumerState<_BottomBarEditor> createState() => _BottomBarEditorState();
}

class _BottomBarEditorState extends ConsumerState<_BottomBarEditor> {
  /// The arrangement on screen. Each edit shows here first and is saved
  /// at once; a failed save puts the saved one back.
  late Arrangement<HomeDestination> _draft = ref.read(homeArrangementProvider);

  Future<void> _save(Arrangement<HomeDestination> next) async {
    setState(() => _draft = next);
    final saved = await persistSettings(
      context,
      () => saveHomeArrangement(ref.read(settingsProvider.notifier), next),
    );
    if (!saved && mounted) {
      setState(() => _draft = ref.read(homeArrangementProvider));
    }
  }

  /// Around a card on the bar: the group's side insets and the row gap
  /// above every card but the first.
  static EdgeInsets _rowPadding(int index) => EdgeInsets.fromLTRB(
    FuncSpacing.lg,
    index == 0 ? 0 : SettingsGroup.rowGap,
    FuncSpacing.lg,
    0,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final draft = _draft;
    return ReorderableListView(
      padding: const EdgeInsets.only(
        top: FuncSpacing.sm,
        bottom: FuncSpacing.xl,
      ),
      buildDefaultDragHandles: false,
      onReorderStart: (_) => AppHaptics.longPress(),
      onReorderItem: (from, to) => _save(draft.reorder(from, to)),
      proxyDecorator: _lifted,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsGroup(
            footer: Text(
              l10n.bottomBarNote(
                minHomeDestinations,
                homeDestinationLabel(context, HomeDestination.me),
                homeDestinationLabel(context, HomeDestination.search),
                homeDestinationLabel(context, HomeDestination.recommended),
              ),
            ),
            children: const [],
          ),
          Reveal(
            child: draft.hidden.isEmpty
                ? null
                : SettingsGroup(
                    title: Text(l10n.arrangementHidden),
                    children: [
                      for (final destination in draft.hidden)
                        Row(
                          children: [
                            Expanded(
                              child: _DestinationSwitch(
                                destination: destination,
                                shown: false,
                                onChanged: (_) =>
                                    _save(draft.show(destination)),
                              ),
                            ),
                            // Where a handle sits on the bar, so both columns of
                            // switches line up.
                            const SizedBox(width: _ShownRow.handleExtent),
                          ],
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.md),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: draft == HomeDestination.defaultArrangement
                    ? null
                    : () => _save(HomeDestination.defaultArrangement),
                icon: const Icon(Icons.restart_alt),
                label: Text(l10n.restoreDefault),
              ),
            ),
          ),
        ],
      ),
      children: [
        for (final (index, destination) in draft.shown.indexed)
          Padding(
            key: ValueKey(destination),
            padding: _rowPadding(index),
            child: _ShownRow(
              index: index,
              destination: destination,
              onHide: draft.canHideDestination(destination)
                  ? () => _save(draft.hide(destination))
                  : null,
            ),
          ),
      ],
    );
  }

  /// The dragged card lifts: a shadow grows under the card, not under the
  /// gap above it.
  Widget _lifted(Widget child, int index, Animation<double> animation) =>
      AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: _rowPadding(index),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: FuncShape.card,
                      boxShadow: BoxShadow.lerpList(
                        const [],
                        kElevationToShadow[_liftElevation],
                        Curves.easeInOut.transform(animation.value),
                      ),
                    ),
                  ),
                ),
              ),
              child!,
            ],
          ),
        ),
        child: child,
      );

  static const _liftElevation = 6;
}

/// A destination on the bar: its switch and its drag handle.
class _ShownRow extends StatelessWidget {
  const _ShownRow({
    required this.index,
    required this.destination,
    required this.onHide,
  });

  final int index;
  final HomeDestination destination;

  /// Null when it has to stay on the bar.
  final VoidCallback? onHide;

  static const handleExtent = 48.0;

  @override
  Widget build(BuildContext context) {
    final onHide = this.onHide;
    return SettingsCard(
      child: Row(
        children: [
          Expanded(
            child: _DestinationSwitch(
              destination: destination,
              shown: true,
              onChanged: onHide == null ? null : (_) => onHide(),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: SizedBox.square(
              dimension: handleExtent,
              child: Icon(
                Icons.drag_handle,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationSwitch extends StatelessWidget {
  const _DestinationSwitch({
    required this.destination,
    required this.shown,
    required this.onChanged,
  });

  final HomeDestination destination;
  final bool shown;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsControl(
      title: Text(homeDestinationLabel(context, destination)),
      subtitle: destination.hideable
          ? null
          : Text(context.l10n.bottomBarMeLocked),
      secondary: Icon(homeDestinationIcon(destination)),
      value: shown,
      onChanged: onChanged,
    );
  }
}
