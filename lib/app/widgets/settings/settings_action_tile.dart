import 'package:material_ui/material_ui.dart';

/// Settings row for showing the current value, running an action or
/// displaying read-only info. Without [onTap] the tile is not clickable
/// and shows no ink splash; [enabled] greys the row out entirely.
class SettingsActionTile extends StatelessWidget {
  const SettingsActionTile({
    super.key,
    required this.title,
    this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final IconData? icon;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return ListTile(
      leading: icon != null ? Icon(icon) : null,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      enabled: enabled,
      onTap: onTap,
    );
  }
}
