import 'package:material_ui/material_ui.dart';

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
      onChanged: onChanged,
    );
  }
}
