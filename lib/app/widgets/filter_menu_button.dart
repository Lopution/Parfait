import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';
import 'app_menu_button.dart';

/// A list filter (D3): an outlined "current value ▾" button over the list
/// that opens a menu of the values, the current one checked. Picking
/// another value plays the select haptic; picking the current one changes
/// nothing. An optional last entry ([moreLabel] / [onMore]) leaves the menu
/// for a fuller picker when the values do not fit a menu.
class FilterMenuButton<T> extends StatelessWidget {
  const FilterMenuButton({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.moreLabel,
    this.onMore,
  }) : assert((moreLabel == null) == (onMore == null));

  /// The button text: the current value, with the filter's name when the
  /// value alone would be unclear ("Tag: All").
  final String label;
  final T value;

  /// The values. Their `checked` is ignored: the option matching [value]
  /// is checked.
  final List<AppMenuEntry<T>> options;
  final ValueChanged<T> onChanged;
  final String? moreLabel;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final moreLabel = this.moreLabel;
    return AppMenuButton<_FilterPick<T>>(
      entries: [
        for (final option in options)
          AppMenuEntry(
            value: _ValuePick(option.value),
            label: option.label,
            icon: option.icon,
            enabled: option.enabled,
            checked: option.value == value,
          ),
        if (moreLabel != null)
          AppMenuEntry(
            value: _MorePick<T>(),
            label: moreLabel,
            icon: Icons.more_horiz,
          ),
      ],
      onSelected: (_, pick) {
        switch (pick) {
          case _MorePick():
            onMore!();
          case _ValuePick(:final value) when value != this.value:
            AppHaptics.select();
            onChanged(value);
          case _ValuePick():
            break;
        }
      },
      anchorBuilder: (context, toggle) => OutlinedButton(
        onPressed: toggle,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

sealed class _FilterPick<T> {
  const _FilterPick();
}

class _ValuePick<T> extends _FilterPick<T> {
  const _ValuePick(this.value);

  final T value;
}

class _MorePick<T> extends _FilterPick<T> {
  const _MorePick();
}
