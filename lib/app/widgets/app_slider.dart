import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';

/// The app's only [Slider]. With [divisions] every step the user moves the
/// thumb across plays one tick haptic (AppHaptics throttles a fast fling).
/// A continuous slider stays silent: without steps there is nothing
/// discrete to confirm, and per-frame vibration would be noise.
class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      onChangeEnd: onChangeEnd,
      onChanged: onChanged == null
          ? null
          : (next) {
              if (divisions != null && next != value) AppHaptics.tick();
              onChanged(next);
            },
    );
  }
}
