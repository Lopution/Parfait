import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';
import '../motion/motion_tokens.dart';
import '../motion/press_scale.dart';

/// The app's only [ChoiceChip] / [FilterChip], with the haptic and the
/// pill press scale built in.
///
/// - [AppChoiceChip.new]: one option of a single-choice group. [onSelected]
///   runs only when an unselected chip is tapped (re-picking the current
///   option is not a change) and plays the select haptic.
/// - [AppChoiceChip.toggle]: an independent on/off chip, rendered as a
///   [FilterChip]; plays toggleOn / toggleOff by the new state.
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required VoidCallback? onSelected,
    this.avatar,
    this.tooltip,
  }) : _onSelected = onSelected,
       _onToggled = null,
       _toggle = false;

  const AppChoiceChip.toggle({
    super.key,
    required this.label,
    required this.selected,
    required ValueChanged<bool>? onChanged,
    this.avatar,
    this.tooltip,
  }) : _onSelected = null,
       _onToggled = onChanged,
       _toggle = true;

  final Widget label;
  final bool selected;
  final Widget? avatar;
  final String? tooltip;
  final VoidCallback? _onSelected;
  final ValueChanged<bool>? _onToggled;
  final bool _toggle;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: MotionTokens.pillPressScale,
      enabled: _onSelected != null || _onToggled != null,
      child: _chip(),
    );
  }

  Widget _chip() {
    if (_toggle) {
      final onToggled = _onToggled;
      return FilterChip(
        label: label,
        selected: selected,
        avatar: avatar,
        tooltip: tooltip,
        onSelected: onToggled == null
            ? null
            : (value) {
                value ? AppHaptics.toggleOn() : AppHaptics.toggleOff();
                onToggled(value);
              },
      );
    }
    final onSelected = _onSelected;
    return ChoiceChip(
      label: label,
      selected: selected,
      avatar: avatar,
      tooltip: tooltip,
      onSelected: onSelected == null
          ? null
          : (_) {
              if (selected) return;
              AppHaptics.select();
              onSelected();
            },
    );
  }
}
