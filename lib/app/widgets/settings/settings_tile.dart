import 'package:material_ui/material_ui.dart';

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    required this.onTap,
    this.icon,
    this.subtitle,
  });

  /// Optional leading icon. Sub-page entries without a distinctive icon
  /// leave it null instead of picking a filler glyph.
  final IconData? icon;
  final String title;
  final VoidCallback onTap;

  /// Optional summary row (the current value, Android-settings style).
  /// When null the tile renders exactly as before.
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return ListTile(
      leading: icon != null ? Icon(icon) : null,
      title: Text(title),
      subtitle: subtitle,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
