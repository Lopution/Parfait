import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/account_store.dart';
import '../../core/search/search_models.dart';
import '../../app/motion/app_overlays.dart';
import 'search_text.dart';
import '../../l10n/context.dart';

Future<SearchFilters?> showSearchFilterSheet(
  BuildContext context, {
  required SearchFilters initial,
  required SearchResultType type,
}) {
  return showAppBottomSheet<SearchFilters>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SearchFilterSheet(initial: initial, type: type),
  );
}

class _SearchFilterSheet extends ConsumerStatefulWidget {
  const _SearchFilterSheet({required this.initial, required this.type});

  final SearchFilters initial;

  /// Illust-only groups (AI-only, ratio, content type, resolution) are
  /// hidden for novel/user searches — the novel endpoint does not accept
  /// those parameters.
  final SearchResultType type;

  @override
  ConsumerState<_SearchFilterSheet> createState() => _SearchFilterSheetState();
}

class _SearchFilterSheetState extends ConsumerState<_SearchFilterSheet> {
  late SearchFilters _filters = widget.initial;

  late final TextEditingController _bookmarkMin;
  late final TextEditingController _bookmarkMax;
  late final TextEditingController _widthMin;
  late final TextEditingController _widthMax;
  late final TextEditingController _heightMin;
  late final TextEditingController _heightMax;

  @override
  void initState() {
    super.initState();
    String text(int? value) => value?.toString() ?? '';
    _bookmarkMin = TextEditingController(text: text(_filters.bookmarkMin));
    _bookmarkMax = TextEditingController(text: text(_filters.bookmarkMax));
    _widthMin = TextEditingController(text: text(_filters.widthMin));
    _widthMax = TextEditingController(text: text(_filters.widthMax));
    _heightMin = TextEditingController(text: text(_filters.heightMin));
    _heightMax = TextEditingController(text: text(_filters.heightMax));
  }

  @override
  void dispose() {
    _bookmarkMin.dispose();
    _bookmarkMax.dispose();
    _widthMin.dispose();
    _widthMax.dispose();
    _heightMin.dispose();
    _heightMax.dispose();
    super.dispose();
  }

  int? _parseBound(String raw) {
    final value = int.tryParse(raw.trim());
    return value == null || value < 0 ? null : value;
  }

  bool get _invalidRange {
    final start = _filters.startDate;
    final end = _filters.endDate;
    return start != null && end != null && start.isAfter(end);
  }

  bool get _isPremium =>
      ref.watch(
        accountStoreProvider.select((async) => async.value?.current?.isPremium),
      ) ??
      false;

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
      // A custom date bound is mutually exclusive with a duration preset —
      // the wire request only ever carries one of them.
      _filters = start
          ? _filters.copyWith(startDate: selected, duration: null)
          : _filters.copyWith(endDate: selected, duration: null);
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
                    context.l10n.searchFilters,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _filters = SearchFilters.defaults;
                    for (final controller in [
                      _bookmarkMin,
                      _bookmarkMax,
                      _widthMin,
                      _widthMax,
                      _heightMin,
                      _heightMax,
                    ]) {
                      controller.clear();
                    }
                  }),
                  child: Text(context.l10n.searchReset),
                ),
              ],
            ),
            _FilterGroup<SearchTarget>(
              title: context.l10n.searchTarget,
              values: SearchTarget.values,
              selected: _filters.target,
              label: (value) => searchText(context, value.labelKey),
              onSelected: (value) =>
                  setState(() => _filters = _filters.copyWith(target: value)),
            ),
            const SizedBox(height: 12),
            _FilterGroup<SearchSort>(
              title: context.l10n.searchSort,
              values: SearchSort.values,
              selected: _filters.sort,
              label: (value) => searchText(context, value.labelKey),
              onSelected: (value) =>
                  setState(() => _filters = _filters.copyWith(sort: value)),
            ),
            // popular_desc is Premium-only server-side; free accounts are
            // silently rerouted to the popular-preview endpoint. Say so.
            if (_filters.sort == SearchSort.popularDesc && !_isPremium)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  context.l10n.searchPopularPreviewHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              context.l10n.searchDuration,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: Text(context.l10n.searchAllTime),
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
                      // A duration preset resolves to a concrete date range
                      // on the wire, so it replaces any custom bounds.
                      () => _filters = _filters.copyWith(
                        duration: value,
                        startDate: null,
                        endDate: null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _DateFilterTile(
              label: context.l10n.searchStartDate,
              value: _dateText(_filters.startDate),
              onTap: () => _pickDate(start: true),
              onClear: _filters.startDate == null
                  ? null
                  : () => setState(
                      () => _filters = _filters.copyWith(startDate: null),
                    ),
            ),
            _DateFilterTile(
              label: context.l10n.searchEndDate,
              value: _dateText(_filters.endDate),
              onTap: () => _pickDate(start: false),
              errorText: _invalidRange
                  ? context.l10n.searchInvalidDateRange
                  : null,
              onClear: _filters.endDate == null
                  ? null
                  : () => setState(
                      () => _filters = _filters.copyWith(endDate: null),
                    ),
            ),
            if (widget.type == SearchResultType.illust) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.searchAiSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final value in SearchAiFilter.values)
                    ChoiceChip(
                      label: Text(searchText(context, value.labelKey)),
                      selected: _filters.aiFilter == value,
                      onSelected: (_) => setState(
                        () => _filters = _filters.copyWith(aiFilter: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.searchBookmarkSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _NumberField(
                      controller: _bookmarkMin,
                      hint: context.l10n.searchMin,
                      onChanged: (value) => setState(
                        () => _filters = _filters.copyWith(
                          bookmarkMin: _parseBound(value),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _NumberField(
                      controller: _bookmarkMax,
                      hint: context.l10n.searchMax,
                      onChanged: (value) => setState(
                        () => _filters = _filters.copyWith(
                          bookmarkMax: _parseBound(value),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.searchRatioSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: Text(context.l10n.searchRatioAny),
                    selected: _filters.ratio == null,
                    onSelected: (_) => setState(
                      () => _filters = _filters.copyWith(ratio: null),
                    ),
                  ),
                  for (final value in SearchRatioPattern.values)
                    ChoiceChip(
                      label: Text(searchText(context, value.labelKey)),
                      selected: _filters.ratio == value,
                      onSelected: (_) => setState(
                        () => _filters = _filters.copyWith(ratio: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.searchContentSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final value in SearchContentType.values)
                    ChoiceChip(
                      label: Text(searchText(context, value.labelKey)),
                      selected: _filters.contentType == value,
                      onSelected: (_) => setState(
                        () => _filters = _filters.copyWith(contentType: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.searchResolutionSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              _BoundRow(
                label: context.l10n.searchWidth,
                minController: _widthMin,
                maxController: _widthMax,
                minHint: context.l10n.searchMin,
                maxHint: context.l10n.searchMax,
                onMinChanged: (value) => setState(
                  () => _filters = _filters.copyWith(
                    widthMin: _parseBound(value),
                  ),
                ),
                onMaxChanged: (value) => setState(
                  () => _filters = _filters.copyWith(
                    widthMax: _parseBound(value),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _BoundRow(
                label: context.l10n.searchHeight,
                minController: _heightMin,
                maxController: _heightMax,
                minHint: context.l10n.searchMin,
                maxHint: context.l10n.searchMax,
                onMinChanged: (value) => setState(
                  () => _filters = _filters.copyWith(
                    heightMin: _parseBound(value),
                  ),
                ),
                onMaxChanged: (value) => setState(
                  () => _filters = _filters.copyWith(
                    heightMax: _parseBound(value),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _invalidRange
                    ? null
                    : () => Navigator.of(context).pop(_filters),
                child: Text(context.l10n.searchApply),
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

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    );
  }
}

class _BoundRow extends StatelessWidget {
  const _BoundRow({
    required this.label,
    required this.minController,
    required this.maxController,
    required this.minHint,
    required this.maxHint,
    required this.onMinChanged,
    required this.onMaxChanged,
  });

  final String label;
  final TextEditingController minController;
  final TextEditingController maxController;
  final String minHint;
  final String maxHint;
  final ValueChanged<String> onMinChanged;
  final ValueChanged<String> onMaxChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 32, child: Text(label)),
        Expanded(
          child: _NumberField(
            controller: minController,
            hint: minHint,
            onChanged: onMinChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _NumberField(
            controller: maxController,
            hint: maxHint,
            onChanged: onMaxChanged,
          ),
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
      title: Text(label),
      subtitle: errorText == null
          ? Text(value)
          : Text(
              errorText,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
      onTap: onTap,
      trailing: onClear == null
          ? const Icon(Icons.calendar_today_outlined)
          : IconButton(
              tooltip: context.l10n.searchClear,
              onPressed: onClear,
              icon: const Icon(Icons.clear),
            ),
    );
  }
}
