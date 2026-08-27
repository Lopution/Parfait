import 'package:flutter/material.dart';

import '../../core/search/search_models.dart';
import 'search_text.dart';

Future<SearchFilters?> showSearchFilterSheet(
  BuildContext context, {
  required SearchFilters initial,
}) {
  return showModalBottomSheet<SearchFilters>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SearchFilterSheet(initial: initial),
  );
}

class SearchFilterSheet extends StatefulWidget {
  const SearchFilterSheet({super.key, required this.initial});

  final SearchFilters initial;

  @override
  State<SearchFilterSheet> createState() => _SearchFilterSheetState();
}

class _SearchFilterSheetState extends State<SearchFilterSheet> {
  late SearchFilters _filters = widget.initial;

  Future<void> _pickDate({required bool start}) async {
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(2007),
      lastDate: DateTime.now(),
      initialDate: start
          ? (_filters.startDate ?? DateTime.now())
          : (_filters.endDate ?? DateTime.now()),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _filters = start
          ? _filters.copyWith(startDate: selected)
          : _filters.copyWith(endDate: selected);
    });
  }

  String _dateText(DateTime? value) {
    if (value == null) return '—';
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    searchText(context, 'searchFilters'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _filters = SearchFilters.defaults),
                  child: Text(searchText(context, 'searchReset')),
                ),
              ],
            ),
            _FilterGroup<SearchTarget>(
              title: searchText(context, 'searchTarget'),
              values: SearchTarget.values,
              selected: _filters.target,
              label: (value) => searchText(context, value.labelKey),
              onSelected: (value) =>
                  setState(() => _filters = _filters.copyWith(target: value)),
            ),
            const SizedBox(height: 12),
            _FilterGroup<SearchSort>(
              title: searchText(context, 'searchSort'),
              values: SearchSort.values,
              selected: _filters.sort,
              label: (value) => searchText(context, value.labelKey),
              onSelected: (value) =>
                  setState(() => _filters = _filters.copyWith(sort: value)),
            ),
            const SizedBox(height: 12),
            Text(
              searchText(context, 'searchDuration'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: Text(searchText(context, 'searchAllTime')),
                  selected: _filters.duration == null,
                  onSelected: (_) => setState(
                    () => _filters = _filters.copyWith(duration: null),
                  ),
                ),
                for (final value in SearchDuration.values)
                  ChoiceChip(
                    label: Text(searchText(context, value.labelKey)),
                    selected: _filters.duration == value,
                    onSelected: (_) => setState(
                      () => _filters = _filters.copyWith(duration: value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _DateFilterTile(
              label: searchText(context, 'searchStartDate'),
              value: _dateText(_filters.startDate),
              onTap: () => _pickDate(start: true),
              onClear: _filters.startDate == null
                  ? null
                  : () => setState(
                      () => _filters = _filters.copyWith(startDate: null),
                    ),
            ),
            _DateFilterTile(
              label: searchText(context, 'searchEndDate'),
              value: _dateText(_filters.endDate),
              onTap: () => _pickDate(start: false),
              onClear: _filters.endDate == null
                  ? null
                  : () => setState(
                      () => _filters = _filters.copyWith(endDate: null),
                    ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_filters),
                child: Text(searchText(context, 'searchApply')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterGroup<T> extends StatelessWidget {
  const _FilterGroup({
    required this.title,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final String title;
  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final value in values)
              ChoiceChip(
                label: Text(label(value)),
                selected: value == selected,
                onSelected: (_) => onSelected(value),
              ),
          ],
        ),
      ],
    );
  }
}

class _DateFilterTile extends StatelessWidget {
  const _DateFilterTile({
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(value),
      onTap: onTap,
      trailing: onClear == null
          ? const Icon(Icons.calendar_today_outlined)
          : IconButton(
              tooltip: searchText(context, 'searchClear'),
              onPressed: onClear,
              icon: const Icon(Icons.clear),
            ),
    );
  }
}
