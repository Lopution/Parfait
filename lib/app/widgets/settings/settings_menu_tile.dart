import 'package:material_ui/material_ui.dart';

import '../../haptics/app_haptics.dart';
import '../app_menu_button.dart';

/// Widest the current value at the end of the row gets before it
/// ellipsizes; the title keeps the rest of the row.
const double _valueMaxWidth = 160;

/// A setting with one value from a short list (two to four options; a
/// longer list is an inline group of `SettingsChoiceTile`s): the row shows
/// the current value at its end ("value ▾"); tapping opens a menu below
/// the row, lined up with its end edge — under the value, clear of the
/// title — the current option checked. The menu is an [AppMenuButton], so
/// an outside press or back closes it without touching the page. Picking
/// another value plays the select haptic; picking the current one changes
/// nothing.
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
    assert(
      options.length >= 2 && options.length <= 4,
      'A menu holds two to four options; list more as SettingsChoiceTiles.',
    );
    final onChanged = this.onChanged;
    final icon = this.icon;
    final current = options.where((option) => option.value == value);
    final theme = Theme.of(context);
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
        // The subtitle's look; ListTile greys it out with the row.
        leadingAndTrailingTextStyle: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _valueMaxWidth),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (current.isNotEmpty)
                Flexible(
                  child: Text(
                    current.first.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
        onTap: toggle,
      ),
    );
  }
}
