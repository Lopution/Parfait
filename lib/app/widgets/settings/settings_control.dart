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
    this.contentPadding,
  });

  final Widget title;
  final bool value;

  /// Null disables the row (the switch greys out and ignores taps).
  final ValueChanged<bool>? onChanged;
  final Widget? subtitle;

  /// Null keeps the list-tile default; a row inside an already padded form
  /// passes [EdgeInsets.zero] so its text lines up with the form.
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return SwitchListTile(
      title: title,
      subtitle: subtitle,
      contentPadding: contentPadding,
      value: value,
      onChanged: onChanged == null
          ? null
          : (value) {
              value ? AppHaptics.toggleOn() : AppHaptics.toggleOff();
              onChanged(value);
            },
    );
  }
}
