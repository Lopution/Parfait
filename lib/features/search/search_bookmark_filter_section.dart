import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/motion/reveal.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_choice_chip.dart';
import '../../core/search/search_bookmark_synthesis.dart';
import '../../core/search/search_models.dart';
import '../../l10n/context.dart';

/// Quick-pick `users入り`-aligned minimum bookmark preset chips and the
/// non-Premium local-filter notice for non-tag search targets.
class SearchBookmarkPresetsAndNotice extends StatelessWidget {
  const SearchBookmarkPresetsAndNotice({
    super.key,
    required this.filters,
    required this.showLocalNotice,
    required this.onSelectMin,
  });

  final SearchFilters filters;
  final bool showLocalNotice;
  final ValueChanged<int?> onSelectMin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: FuncSpacing.sm,
          runSpacing: FuncSpacing.xs,
          children: [
            for (final preset in kBookmarkMinPresets)
              AppChoiceChip(
                key: ValueKey('search-bookmark-preset-$preset'),
                label: Text('${AppFormat.count(context, preset)}+'),
                selected: filters.bookmarkMin == preset,
                onSelected: () =>
                    onSelectMin(filters.bookmarkMin == preset ? null : preset),
              ),
          ],
        ),
        Reveal(
          child: showLocalNotice
              ? Padding(
                  padding: const EdgeInsets.only(top: FuncSpacing.xs),
                  child: Text(
                    l10n.searchBookmarkLocalFilterHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : null,
        ),
        const SizedBox(height: FuncSpacing.sm),
      ],
    );
  }
}

/// Date selector row used for search start/end bounds inside `SearchFilterSheet`.
class SearchDateFilterTile extends StatelessWidget {
  const SearchDateFilterTile({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
    this.errorText,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final errorText = this.errorText;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      title: Text(label),
      subtitle: errorText == null
          ? Text(value)
          : Text(
              errorText,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
      onTap: onTap,
      trailing: onClear == null
          ? const Icon(AppIcons.calendar)
          : IconButton(
              tooltip: context.l10n.searchClear,
              onPressed: onClear,
              icon: const Icon(UiIcons.close),
            ),
    );
  }
}
