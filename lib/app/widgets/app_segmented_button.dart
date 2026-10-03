import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';

/// The app's only [SegmentedButton]. Parameters pass straight through; the
/// wrapper adds the select haptic when the user picks a different segment.
/// An empty selection (re-tapping the selected segment with
/// [emptySelectionAllowed]) is not a change and stays silent.
class AppSegmentedButton<T> extends StatelessWidget {
  const AppSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.emptySelectionAllowed = false,
    this.haptics = true,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon;
  final bool emptySelectionAllowed;

  /// Off when the host plays its own haptic for the pick (the haptic
  /// strength picker previews the chosen level instead).
  final bool haptics;

  @override
  Widget build(BuildContext context) {
    final onSelectionChanged = this.onSelectionChanged;
    return SegmentedButton<T>(
      segments: segments,
      selected: selected,
      showSelectedIcon: showSelectedIcon,
      emptySelectionAllowed: emptySelectionAllowed,
      onSelectionChanged: onSelectionChanged == null
          ? null
          : (selection) {
              if (haptics &&
                  selection.isNotEmpty &&
                  !setEquals(selection, selected)) {
                AppHaptics.select();
              }
              onSelectionChanged(selection);
            },
    );
  }
}
