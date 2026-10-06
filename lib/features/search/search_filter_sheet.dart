import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../core/auth/account_store.dart';
import '../../core/search/search_models.dart';
import '../../app/motion/app_overlays.dart';
import 'search_text.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_choice_chip.dart';

/// What the filter sheet applies: the edited set plus whether the user also
/// asked to persist it as that type's default ("设为默认").
typedef SearchFilterSheetResult = ({SearchFilters filters, bool makeDefault});

Future<SearchFilterSheetResult?> showSearchFilterSheet(
  BuildContext context, {
  required SearchFilters initial,
  bool offerSetDefault = false,
}) {
  return showAppBottomSheet<SearchFilterSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _SearchFilterSheet(initial: initial, offerSetDefault: offerSetDefault),
  );
}

class _SearchFilterSheet extends ConsumerStatefulWidget {
  const _SearchFilterSheet({
    required this.initial,
    required this.offerSetDefault,
  });

  final SearchFilters initial;

  /// The result page offers "设为默认" so a session edit can be promoted to
  /// the persisted default explicitly — the input page's draft never does.
  final bool offerSetDefault;

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
  late final TextEditingController _textLengthMin;
  late final TextEditingController _textLengthMax;

  IllustSearchFilters? get _illust => switch (_filters) {
    final IllustSearchFilters f => f,
    _ => null,
  };

  NovelSearchFilters? get _novel => switch (_filters) {
    final NovelSearchFilters f => f,
    _ => null,
  };

  SearchFilters get _defaults => switch (widget.initial.type) {
    SearchResultType.illust => IllustSearchFilters.defaults,
    SearchResultType.novel => NovelSearchFilters.defaults,
    // The sheet is never opened for user results.
    SearchResultType.user => IllustSearchFilters.defaults,
  };

  @override
  void initState() {
    super.initState();
    String text(int? value) => value?.toString() ?? '';
    _bookmarkMin = TextEditingController(text: text(_filters.bookmarkMin));
    _bookmarkMax = TextEditingController(text: text(_filters.bookmarkMax));
    _widthMin = TextEditingController(text: text(_illust?.widthMin));
    _widthMax = TextEditingController(text: text(_illust?.widthMax));
    _heightMin = TextEditingController(text: text(_illust?.heightMin));
    _heightMax = TextEditingController(text: text(_illust?.heightMax));
    _textLengthMin = TextEditingController(text: text(_novel?.textLengthMin));
    _textLengthMax = TextEditingController(text: text(_novel?.textLengthMax));
  }

  @override
  void dispose() {
    _bookmarkMin.dispose();
    _bookmarkMax.dispose();
    _widthMin.dispose();
    _widthMax.dispose();
    _heightMin.dispose();
    _heightMax.dispose();
    _textLengthMin.dispose();
    _textLengthMax.dispose();
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
          ? _filters.copyShared(startDate: selected, duration: null)
          : _filters.copyShared(endDate: selected, duration: null);
    });
  }

  String _dateText(BuildContext context, DateTime? value) {
    if (value == null) return '—';
    return AppFormat.date(context, value);
  }

  void _pop({required bool makeDefault}) =>
      Navigator.of(context).pop((filters: _filters, makeDefault: makeDefault));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          FuncSpacing.xl,
          FuncSpacing.lg,
          FuncSpacing.xl,
          FuncSpacing.lg,
        ),
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
                    _filters = _defaults;
                    for (final controller in [
                      _bookmarkMin,
                      _bookmarkMax,
                      _widthMin,
                      _widthMax,
                      _heightMin,
                      _heightMax,
                      _textLengthMin,
                      _textLengthMax,
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
              // Each type only offers — and only ever sends — its own
              // search-range values.
              values: _filters.targetOptions,
              selected: _filters.normalizedTarget,
              label: (value) => searchText(context, value.labelKey),
              onSelected: (value) =>
                  setState(() => _filters = _filters.copyShared(target: value)),
            ),
            const SizedBox(height: FuncSpacing.md),
            _FilterGroup<SearchSort>(
              title: context.l10n.searchSort,
              // Gendered popularity sorts are illust-only — the novel sheet
              // does not show them, so the selected and the requested value
              // can no longer disagree.
              values: _filters.sortOptions,
              selected: _filters.normalizedSort,
              label: (value) => searchText(context, value.labelKey),
              onSelected: (value) =>
                  setState(() => _filters = _filters.copyShared(sort: value)),
            ),
            // Popularity sorts are Premium-only server-side; free accounts
            // are silently rerouted to the popular-preview endpoint for any
            // of them — the hint covers the gendered sorts too.
            if (_filters.normalizedSort.isPopular && !_isPremium)
              Padding(
                padding: const EdgeInsets.only(top: FuncSpacing.xs),
                child: Text(
                  context.l10n.searchPopularPreviewHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: FuncSpacing.md),
            Text(
              context.l10n.searchDuration,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: FuncSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                AppChoiceChip(
                  label: Text(context.l10n.searchAllTime),
                  // "All time" means unconstrained: a custom date bound is
                  // still sent on the wire even when duration is null, so
                  // the chip is neither selected by nor allowed to leave
                  // behind stale bounds.
                  selected:
                      _filters.duration == null &&
                      _filters.startDate == null &&
                      _filters.endDate == null,
                  onSelected: () => setState(
                    () => _filters = _filters.copyShared(
                      duration: null,
                      startDate: null,
                      endDate: null,
                    ),
                  ),
                ),
                for (final value in SearchDuration.values)
                  AppChoiceChip(
                    label: Text(searchText(context, value.labelKey)),
                    selected: _filters.duration == value,
                    onSelected: () => setState(
                      // A duration preset resolves to a concrete date range
                      // on the wire, so it replaces any custom bounds.
                      () => _filters = _filters.copyShared(
                        duration: value,
                        startDate: null,
                        endDate: null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: FuncSpacing.md),
            _DateFilterTile(
              label: context.l10n.searchStartDate,
              value: _dateText(context, _filters.startDate),
              onTap: () => _pickDate(start: true),
              onClear: _filters.startDate == null
                  ? null
                  : () => setState(
                      () => _filters = _filters.copyShared(startDate: null),
                    ),
            ),
            _DateFilterTile(
              label: context.l10n.searchEndDate,
              value: _dateText(context, _filters.endDate),
              onTap: () => _pickDate(start: false),
              errorText: _invalidRange
                  ? context.l10n.searchInvalidDateRange
                  : null,
              onClear: _filters.endDate == null
                  ? null
                  : () => setState(
                      () => _filters = _filters.copyShared(endDate: null),
                    ),
            ),
            const SizedBox(height: FuncSpacing.md),
            Text(
              context.l10n.searchAiSection,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: FuncSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final value in SearchAiFilter.values)
                  AppChoiceChip(
                    label: Text(searchText(context, value.labelKey)),
                    selected: _filters.aiFilter == value,
                    onSelected: () => setState(
                      () => _filters = _filters.copyShared(aiFilter: value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: FuncSpacing.md),
            Text(
              context.l10n.searchBookmarkSection,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: FuncSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _NumberField(
                    controller: _bookmarkMin,
                    hint: context.l10n.searchMin,
                    onChanged: (value) => setState(
                      () => _filters = _filters.copyShared(
                        bookmarkMin: _parseBound(value),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: FuncSpacing.md),
                Expanded(
                  child: _NumberField(
                    controller: _bookmarkMax,
                    hint: context.l10n.searchMax,
                    onChanged: (value) => setState(
                      () => _filters = _filters.copyShared(
                        bookmarkMax: _parseBound(value),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_illust case final illust?) ...[
              const SizedBox(height: FuncSpacing.md),
              Text(
                context.l10n.searchRatioSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: FuncSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  AppChoiceChip(
                    label: Text(context.l10n.searchRatioAny),
                    selected: illust.ratio == null,
                    onSelected: () =>
                        setState(() => _filters = illust.copyWith(ratio: null)),
                  ),
                  for (final value in SearchRatioPattern.values)
                    AppChoiceChip(
                      label: Text(searchText(context, value.labelKey)),
                      selected: illust.ratio == value,
                      onSelected: () => setState(
                        () => _filters = illust.copyWith(ratio: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: FuncSpacing.md),
              Text(
                context.l10n.searchContentSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: FuncSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final value in SearchContentType.values)
                    AppChoiceChip(
                      label: Text(searchText(context, value.labelKey)),
                      selected: illust.contentType == value,
                      onSelected: () => setState(
                        () => _filters = illust.copyWith(contentType: value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: FuncSpacing.md),
              Text(
                context.l10n.searchResolutionSection,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: FuncSpacing.sm),
              _BoundRow(
                label: context.l10n.searchWidth,
                minController: _widthMin,
                maxController: _widthMax,
                minHint: context.l10n.searchMin,
                maxHint: context.l10n.searchMax,
                onMinChanged: (value) => setState(
                  () =>
                      _filters = illust.copyWith(widthMin: _parseBound(value)),
                ),
                onMaxChanged: (value) => setState(
                  () =>
                      _filters = illust.copyWith(widthMax: _parseBound(value)),
                ),
              ),
              const SizedBox(height: FuncSpacing.sm),
              _BoundRow(
                label: context.l10n.searchHeight,
                minController: _heightMin,
                maxController: _heightMax,
                minHint: context.l10n.searchMin,
                maxHint: context.l10n.searchMax,
                onMinChanged: (value) => setState(
                  () =>
                      _filters = illust.copyWith(heightMin: _parseBound(value)),
                ),
                onMaxChanged: (value) => setState(
                  () =>
                      _filters = illust.copyWith(heightMax: _parseBound(value)),
                ),
              ),
            ],
            if (_novel case final novel?) ...[
              const SizedBox(height: FuncSpacing.md),
              Text(
                context.l10n.searchTextLength,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: FuncSpacing.sm),
              _BoundRow(
                label: context.l10n.searchChars,
                minController: _textLengthMin,
                maxController: _textLengthMax,
                minHint: context.l10n.searchMin,
                maxHint: context.l10n.searchMax,
                onMinChanged: (value) => setState(
                  () => _filters = novel.copyWith(
                    textLengthMin: _parseBound(value),
                  ),
                ),
                onMaxChanged: (value) => setState(
                  () => _filters = novel.copyWith(
                    textLengthMax: _parseBound(value),
                  ),
                ),
              ),
              const SizedBox(height: FuncSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  AppChoiceChip(
                    label: Text(context.l10n.searchOriginalOnly),
                    selected: novel.originalOnly,
                    onSelected: () => setState(
                      () => _filters = novel.copyWith(
                        originalOnly: !novel.originalOnly,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: FuncSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _invalidRange
                    ? null
                    : () => _pop(makeDefault: false),
                child: Text(context.l10n.searchApply),
              ),
            ),
            if (widget.offerSetDefault) ...[
              const SizedBox(height: FuncSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _invalidRange
                      ? null
                      : () => _pop(makeDefault: true),
                  child: Text(context.l10n.searchSetDefault),
                ),
              ),
            ],
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
        const SizedBox(height: FuncSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final value in values)
              AppChoiceChip(
                label: Text(label(value)),
                selected: value == selected,
                onSelected: () => onSelected(value),
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
        SizedBox(width: 48, child: Text(label)),
        Expanded(
          child: _NumberField(
            controller: minController,
            hint: minHint,
            onChanged: onMinChanged,
          ),
        ),
        const SizedBox(width: FuncSpacing.md),
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
