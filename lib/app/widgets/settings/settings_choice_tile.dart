import 'package:material_ui/material_ui.dart';

/// Single-choice settings row (D1): `ListTile(selected:)` so screen readers
/// announce the selected entry, with a primary-coloured check as its visual
/// marker. `RadioListTile` is deprecated on this Flutter version, so the
/// check stays the indicator.
class SettingsChoiceTile extends StatelessWidget {
  const SettingsChoiceTile({
    super.key,
    required this.title,
    required this.selected,
    this.subtitle,
    this.onTap,
  });

  final Widget title;
  final Widget? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: title,
      subtitle: subtitle,
      selected: selected,
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
