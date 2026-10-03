import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';
import '../theme/func_semantic_tokens.dart';
import 'fit_label.dart';

/// One segment of an [AppSegmentedButton].
@immutable
final class AppSegment<T> {
  const AppSegment({required this.value, required this.label});

  final T value;
  final String label;
}

/// The app's only [SegmentedButton]: single choice, equal-width segments,
/// no check mark — the selected fill marks the choice, so labels never
/// shift when the selection moves. When the row is narrower than the
/// labels need, every label shrinks by one shared scale down to
/// [LabelFit.minScale] and only then ellipsizes ([FitLabel]); in an
/// unbounded row (the scrolling type switch) labels keep their size.
/// Picking a different segment plays the select haptic.
class AppSegmentedButton<T> extends StatelessWidget {
  const AppSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.onReselected,
    this.haptics = true,
  });

  final List<AppSegment<T>> segments;
  final T selected;

  /// A different segment was picked. Null disables the control.
  final ValueChanged<T>? onSelected;

  /// The selected segment was tapped again (hosts scroll to top).
  final VoidCallback? onReselected;

  /// Off when the host plays its own haptic for the pick (the haptic
  /// strength picker previews the chosen level instead).
  final bool haptics;

  static const _padding = EdgeInsets.symmetric(horizontal: FuncSpacing.md);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Measured and drawn with the same style; the button adds the colour.
    final textStyle = theme.textTheme.labelLarge!;
    // Buttons widen or narrow their padding by the visual density.
    final sidePadding = math.max(
      0.0,
      _padding.left + theme.visualDensity.baseSizeAdjustment.dx,
    );
    final onSelected = this.onSelected;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = LabelFit.group(
          labels: [for (final segment in segments) segment.label],
          style: textStyle,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          // SegmentedButton caps every segment at an equal share.
          slotWidth: constraints.maxWidth / segments.length - 2 * sidePadding,
        );
        return SegmentedButton<T>(
          segments: [
            for (final segment in segments)
              ButtonSegment<T>(
                value: segment.value,
                label: FitLabel(segment.label, fit: fit),
              ),
          ],
          selected: {selected},
          showSelectedIcon: false,
          // A re-tap reports an empty selection; only hosts that listen
          // for it allow one.
          emptySelectionAllowed: onReselected != null,
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(_padding),
            textStyle: WidgetStatePropertyAll(textStyle),
          ),
          onSelectionChanged: onSelected == null
              ? null
              : (selection) {
                  if (selection.isEmpty) {
                    onReselected?.call();
                    return;
                  }
                  final value = selection.single;
                  if (value == selected) return;
                  if (haptics) AppHaptics.select();
                  onSelected(value);
                },
        );
      },
    );
  }
}
