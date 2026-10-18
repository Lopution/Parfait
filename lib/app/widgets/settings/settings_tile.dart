import 'package:material_ui/material_ui.dart';

import '../../theme/category_colors.dart';
import 'settings_anchor.dart';

/// A row that opens another page; its chevron says so. On a sub-page the
/// icon is bare, like the setting rows around it (SET-08).
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.subtitle,
  }) : tone = null;

  /// An entry of a top-level page (the settings index, the Me tab): the
  /// icon sits in a circle of its group's [tone], setting the categories
  /// apart.
  const SettingsTile.topLevel({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.subtitle,
    required CategoryTone this.tone,
  });

  /// The circle's colors; null on a sub-page, whose icon is bare.
  final CategoryTone? tone;

  /// Optional leading icon. Sub-page entries without a distinctive icon
  /// leave it null instead of picking a filler glyph.
  final IconData? icon;

  /// The title; defaults to the title of [setting].
  final String? title;

  /// The catalog entry this row is the place of (settings search).
  final SettingsEntry? setting;
  final VoidCallback onTap;

  /// Optional summary row (the current value, Android-settings style).
  /// When null the tile renders exactly as before.
  final Widget? subtitle;

  /// Diameter of the tonal circle behind the icon.
  static const double iconDiameter = 40;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    final tone = this.tone;
    return anchorSettingsRow(
      setting,
      ListTile(
        leading: icon == null
            ? null
            : tone == null
            ? Icon(icon)
            : SizedBox.square(
                dimension: iconDiameter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tone.fill,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: tone.ink),
                ),
              ),
        title: Text(settingsRowTitle(context, title, setting)),
        subtitle: subtitle,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
