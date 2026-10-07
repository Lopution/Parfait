import 'package:material_ui/material_ui.dart';

import 'settings_anchor.dart';

/// A row that opens another page. Its icon sits in a tonal circle, which
/// sets the page entries apart from the settings themselves.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.title,
    this.setting,
    required this.onTap,
    this.icon,
    this.subtitle,
  });

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
    final scheme = Theme.of(context).colorScheme;
    return anchorSettingsRow(
      setting,
      ListTile(
        leading: icon == null
            ? null
            : SizedBox.square(
                dimension: iconDiameter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: scheme.onSecondaryContainer),
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
