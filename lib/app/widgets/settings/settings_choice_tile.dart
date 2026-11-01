import 'package:material_ui/material_ui.dart';

import '../../haptics/app_haptics.dart';

/// Single-choice settings row (D1): `ListTile(selected:)` so screen readers
/// announce the selected entry, with a primary-coloured check as its visual
/// marker. `RadioListTile` is deprecated on this Flutter version, so the
/// check stays the indicator. Picking another entry plays the select
/// haptic; tapping the selected one stays silent.
class SettingsChoiceTile extends StatelessWidget {
  const SettingsChoiceTile({
    super.key,
    required this.title,
    required this.selected,
    this.subtitle,
    this.onTap,
    this.contentPadding,
  });

  final Widget title;
  final Widget? subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final onTap = this.onTap;
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = this.subtitle;
    return ListTile(
      contentPadding: contentPadding,
      title: title,
      // Selection tints the title and the check; the description stays
      // secondary text (THEME-07).
      subtitle: subtitle == null
          ? null
          : DefaultTextStyle.merge(
              style: TextStyle(color: colorScheme.onSurfaceVariant),
              child: subtitle,
            ),
      selected: selected,
      trailing: selected ? Icon(Icons.check, color: colorScheme.primary) : null,
      onTap: onTap == null
          ? null
          : () {
              if (!selected) AppHaptics.select();
              onTap();
            },
    );
  }
}
