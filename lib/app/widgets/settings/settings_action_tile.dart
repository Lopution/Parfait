import 'package:material_ui/material_ui.dart';

import 'settings_anchor.dart';

/// Settings row for showing the current value, running an action or
/// displaying read-only info. Without [onTap] the tile is not clickable
/// and shows no ink splash; [enabled] greys the row out entirely.
class SettingsActionTile extends StatelessWidget {
  const SettingsActionTile({
    super.key,
    this.title,
    this.setting,
    this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final IconData? icon;

  /// The title; defaults to the title of [setting].
  final Widget? title;

  /// The catalog entry this row is the place of (settings search).
  final SettingsEntry? setting;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return anchorSettingsRow(
      setting,
      ListTile(
        leading: icon != null ? Icon(icon) : null,
        title: title ?? Text(settingsRowTitle(context, null, setting)),
        subtitle: subtitle,
        trailing: trailing,
        enabled: enabled,
        onTap: onTap,
      ),
    );
  }
}
