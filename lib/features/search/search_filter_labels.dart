import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../core/search/search_models.dart';
import '../../l10n/context.dart';
import 'search_text.dart';

/// One label per filter field that differs from its type's default, in
/// sheet order. The result page shows them as chips; their count is the
/// filter button's badge.
List<String> searchFilterLabels(BuildContext context, SearchFilters filters) {
  final l10n = context.l10n;
  String pixels(int value) => '$value';
  return [
    if (filters.normalizedTarget != SearchTarget.partialMatchForTags)
      searchText(context, filters.normalizedTarget.labelKey),
    if (filters.normalizedSort != SearchSort.dateDesc)
      searchText(context, filters.normalizedSort.labelKey),
    if (filters.duration != null)
      searchText(context, filters.duration!.labelKey),
    ?_dateLabel(context, filters),
    if (filters.aiFilter != SearchAiFilter.all)
      searchText(context, filters.aiFilter.labelKey),
    // Each type only displays its own dimensions.
    ...switch (filters) {
      final IllustSearchFilters f => [
        if (f.ratio != null) searchText(context, f.ratio!.labelKey),
        if (f.contentType != SearchContentType.illustAndMangaAndUgoira)
          searchText(context, f.contentType.labelKey),
      ],
      final NovelSearchFilters f => [
        if (f.originalOnly) l10n.searchOriginalOnly,
      ],
    },
    ?_rangeLabel(
      context,
      l10n.searchBookmarkSection,
      filters.bookmarkMin,
      filters.bookmarkMax,
      (value) => AppFormat.count(context, value),
    ),
    ...switch (filters) {
      final IllustSearchFilters f => [
        ?_rangeLabel(context, l10n.searchWidth, f.widthMin, f.widthMax, pixels),
        ?_rangeLabel(
          context,
          l10n.searchHeight,
          f.heightMin,
          f.heightMax,
          pixels,
        ),
      ],
      final NovelSearchFilters f => [
        ?_rangeLabel(
          context,
          l10n.searchTextLength,
          f.textLengthMin,
          f.textLengthMax,
          pixels,
        ),
      ],
    },
  ];
}

String? _dateLabel(BuildContext context, SearchFilters filters) {
  final l10n = context.l10n;
  final start = filters.startDate == null
      ? null
      : AppFormat.date(context, filters.startDate!);
  final end = filters.endDate == null
      ? null
      : AppFormat.date(context, filters.endDate!);
  return switch ((start, end)) {
    (null, null) => null,
    (final start?, null) => l10n.searchDateFrom(start),
    (null, final end?) => l10n.searchDateUntil(end),
    (final start?, final end?) => l10n.searchDateBetween(start, end),
  };
}

/// One bounded filter as "label, bound(s)"; null when neither bound is
/// set. [format] renders a bound (compact counts or raw pixels).
String? _rangeLabel(
  BuildContext context,
  String label,
  int? min,
  int? max,
  String Function(int value) format,
) {
  final l10n = context.l10n;
  return switch ((min, max)) {
    (null, null) => null,
    (final min?, null) => l10n.searchRangeAtLeast(label, format(min)),
    (null, final max?) => l10n.searchRangeAtMost(label, format(max)),
    (final min?, final max?) => l10n.searchRangeBetween(
      label,
      format(min),
      format(max),
    ),
  };
}

/// The top-bar entry to the filter sheet, badged with how many fields of
/// [filters] are active.
class SearchFilterButton extends StatelessWidget {
  const SearchFilterButton({
    super.key,
    required this.filters,
    required this.onPressed,
    this.muted = false,
  });

  final SearchFilters filters;
  final VoidCallback onPressed;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final count = searchFilterLabels(context, filters).length;
    final l10n = context.l10n;
    return IconButton(
      tooltip: count == 0
          ? l10n.searchFilters
          : l10n.searchFiltersActive(count),
      onPressed: onPressed,
      color: muted ? Theme.of(context).colorScheme.onSurfaceVariant : null,
      icon: Badge(
        isLabelVisible: count > 0,
        // The tooltip already reads the count.
        label: ExcludeSemantics(child: Text('$count')),
        child: const Icon(Icons.tune),
      ),
    );
  }
}
