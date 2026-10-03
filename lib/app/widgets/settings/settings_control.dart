import 'package:material_ui/material_ui.dart';

import '../../haptics/app_haptics.dart';

/// Settings switch row. Owns the toggle haptic: only a user flip is felt,
/// never an external value change.
class SettingsControl extends StatelessWidget {
  const SettingsControl({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final Widget title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: (value) {
        value ? AppHaptics.toggleOn() : AppHaptics.toggleOff();
        onChanged(value);
      },
    );
  }
}
