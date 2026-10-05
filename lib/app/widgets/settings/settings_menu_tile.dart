import 'package:material_ui/material_ui.dart';

import '../../haptics/app_haptics.dart';
import '../app_menu_button.dart';

/// A setting with one value from a short list: the row shows the current
/// value; tapping opens a menu anchored to the row, the current option
/// checked. The menu is an [AppMenuButton], so an outside press or back
/// closes it without touching the page. Picking another value plays the
/// select haptic; picking the current one changes nothing.
class SettingsMenuTile<T> extends StatelessWidget {
  const SettingsMenuTile({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon,
    this.haptics = true,
  });

  final String title;
  final T value;

  /// The choices. Their `checked` is ignored: the tile checks the option
  /// matching [value].
  final List<AppMenuEntry<T>> options;

  /// A different option was picked. Null disables the row.
  final ValueChanged<T>? onChanged;

  final IconData? icon;

  /// Off when the host plays its own haptic for the pick (the haptic
  /// strength row previews the chosen level instead).
  final bool haptics;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final icon = this.icon;
    final current = options.where((option) => option.value == value);
    return AppMenuButton<T>(
      entries: [
        for (final option in options)
          AppMenuEntry<T>(
            value: option.value,
            label: option.label,
            icon: option.icon,
            enabled: option.enabled,
            checked: option.value == value,
          ),
      ],
      onSelected: (_, picked) {
        if (onChanged == null || picked == value) return;
        if (haptics) AppHaptics.select();
        onChanged(picked);
      },
      anchorBuilder: (context, toggle) => ListTile(
        enabled: onChanged != null,
        leading: icon == null ? null : Icon(icon),
        title: Text(title),
        subtitle: current.isEmpty ? null : Text(current.first.label),
        trailing: const Icon(Icons.arrow_drop_down),
        onTap: toggle,
      ),
    );
  }
}
