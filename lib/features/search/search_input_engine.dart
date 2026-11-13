import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/navigation/routes.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/display_actions.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/search_field_button.dart';
import '../../app/widgets/search_keyword_pills.dart';
import '../../app/widgets/tag_chips.dart';
import '../../app/widgets/undo_snack_bar.dart';
import '../../core/search/search_autocomplete_controller.dart';
import '../../core/search/search_history.dart';
import '../../core/search/search_keywords.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_repository.dart';
import '../../core/search/search_shortcut.dart';
import '../../core/search/search_trending_controller.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import 'search_filter_labels.dart';
import 'search_filter_sheet.dart';
import 'search_section_header.dart';
import 'search_text.dart';

/// Search input with the three beta56 result tabs and cancellable
/// suggestions, shared by the full input page and the docked panel (R10).
///
/// The engine owns the text, the kind tabs, the filter drafts and the
/// autocomplete subscription; [builder] places the four pieces it produces —
/// the field, the tabs, the filter button and the history/suggestion body —
/// in the host's own chrome.
class SearchInputEngine extends ConsumerStatefulWidget {
  const SearchInputEngine({
    super.key,
    required this.onSubmit,
    required this.builder,
    this.initialKeyword = '',
    this.initialType = SearchResultType.illust,
    this.initialIllustFilters,
    this.initialNovelFilters,
    this.onTypeChanged,
    this.onShortcut,
  });

  final String initialKeyword;
  final SearchResultType initialType;

  /// Drafts handed over from another input surface (the docked panel
  /// narrowing into this page, R10); the persisted defaults otherwise.
  final IllustSearchFilters? initialIllustFilters;
  final NovelSearchFilters? initialNovelFilters;

  /// The host rewrites its own route when the kind changes (the full page
  /// keeps its URL's type current); the docked panel changes nothing.
  final void Function(String keyword, SearchResultType type)? onTypeChanged;

  /// The user searched [query]. Autocomplete is cancelled and the keyword
  /// is in the history already; the host moves to the results.
  final ValueChanged<SearchQuery> onSubmit;

  /// What an id or a link in the draft opens; the docked panel handles it
  /// itself so the panel can close first (R10).
  final ValueChanged<SearchShortcut>? onShortcut;

  final SearchInputEngineBuilder builder;

  @override
  ConsumerState<SearchInputEngine> createState() => SearchInputEngineState();
}

/// The controls the engine wires up, for the host to place.
class SearchInputEngineParts {
  const SearchInputEngineParts({
    required this.field,
    required this.tabs,
    required this.filterButton,
    required this.body,
  });

  final Widget field;
  final PreferredSizeWidget tabs;
  final Widget filterButton;
  final Widget body;
}

typedef SearchInputEngineBuilder =
    Widget Function(BuildContext context, SearchInputEngineParts parts);

class SearchInputEngineState extends ConsumerState<SearchInputEngine>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final SearchKeywordController _textController;
  late final FocusNode _focusNode;
  late int _selectedIndex;
  Animation<double>? _routeAnimation;

  static const _types = SearchResultType.values;

  /// The draft exactly as typed, trailing spaces included: handing it to
  /// another input surface must not rewrite it. Submitting trims instead.
  String get draft => _textController.text;

  /// The kind the field is on.
  SearchResultType get type => _types[_selectedIndex];

  @override
  void initState() {
    super.initState();
    _selectedIndex = _types.indexOf(widget.initialType);
    _tabController = TabController(
      length: _types.length,
      vsync: this,
      initialIndex: _selectedIndex,
    )..addListener(_onTabChanged);
    final initial = widget.initialKeyword;
    _textController = SearchKeywordController()
      ..value = TextEditingValue(
        text: initial,
        selection: TextSelection.collapsed(offset: initial.length),
      )
      ..addListener(_complete);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _complete();
      // The field exists to type a query: focus it on arrival so the
      // keyboard is up without a second tap (pre-go_router behaviour).
      // But not mid-transition: _RoutePopSnapshot freezes the page into a
      // fixed-size texture while the IME animates viewInsets, so a keyboard
      // that opens during the push would let the route fly in squeezed and
      // then snap when the snapshot releases. Waiting for the transition to
      // complete keeps both animations out of each other's way.
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _focusNode.requestFocus();
        return;
      }
      _routeAnimation = animation;
      animation.addStatusListener(_focusWhenRouteSettles);
    });
  }

  void _focusWhenRouteSettles(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _routeAnimation?.removeStatusListener(_focusWhenRouteSettles);
    _routeAnimation = null;
    if (mounted) _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_focusWhenRouteSettles);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex ||
        _tabController.indexIsChanging) {
      return;
    }
    setState(() => _selectedIndex = _tabController.index);
    widget.onTypeChanged?.call(_textController.text, _types[_selectedIndex]);
  }

  void _submit() {
    final keyword = _textController.text.trim();
    if (keyword.isEmpty) {
      showAppSnackBar(context, context.l10n.searchInputEmpty);
      return;
    }
    _search(keyword);
  }

  /// Searches [keyword] with this session's filter drafts. An id or a pixiv
  /// link stays out of the history; the host's navigation opens what it
  /// names (see [openSearchResults]).
  void _search(String keyword) {
    ref.read(searchAutocompleteProvider.notifier).cancel();
    if (searchShortcutFor(keyword, type) == null) {
      unawaited(ref.read(searchHistoryProvider.notifier).record(keyword));
    }
    widget.onSubmit(_query(keyword));
  }

  SearchQuery _query(String keyword) {
    return searchQueryForType(
      type,
      keyword: keyword,
      illustFilters: _illustFilters,
      novelFilters: _novelFilters,
    );
  }

  /// Per-type filter drafts for this input session. Seeded from the
  /// persisted defaults — or from the surface that handed the session over
  /// (R10) — and edited in place: the submitted query carries this draft,
  /// nothing else writes it.
  late IllustSearchFilters _illustFilters =
      widget.initialIllustFilters ?? ref.read(searchIllustFiltersProvider);
  late NovelSearchFilters _novelFilters =
      widget.initialNovelFilters ?? ref.read(searchNovelFiltersProvider);

  /// The two drafts, for a host handing the session to another input
  /// surface (R10 narrowing).
  IllustSearchFilters get illustFilters => _illustFilters;
  NovelSearchFilters get novelFilters => _novelFilters;

  SearchFilters get _filters =>
      type == SearchResultType.novel ? _novelFilters : _illustFilters;

  Future<void> _editFilters() async {
    final result = await showSearchFilterSheet(context, initial: _filters);
    if (!mounted || result == null) return;
    // The draft belongs to this input session only — persisting it is the
    // result page's "设为默认" job, not the apply button's.
    setState(() {
      switch (result.filters) {
        case final IllustSearchFilters f:
          _illustFilters = f;
        case final NovelSearchFilters f:
          _novelFilters = f;
      }
    });
  }

  /// Asks autocomplete for the keyword at the caret whenever the text or
  /// the caret moves to another one. An id or a link opens directly; tag
  /// suggestions for it would only fill the list with noise.
  void _complete() {
    final value = _textController.value;
    final range = keywordAtCaret(value);
    final query = range == null || searchShortcutFor(value.text, type) != null
        ? ''
        : completionQueryOf(range.textInside(value.text));
    // A caret moving within the keyword asks nothing new.
    if (query == ref.read(searchAutocompleteProvider).keyword) return;
    ref.read(searchAutocompleteProvider.notifier).update(query);
  }

  /// Puts [keyword] in the field to edit it further.
  void _fill(String keyword) => _edit(
    TextEditingValue(
      text: keyword,
      selection: TextSelection.collapsed(offset: keyword.length),
    ),
  );

  void _edit(TextEditingValue value) {
    _textController.value = value;
    _focusNode.requestFocus();
  }

  void _clear() {
    _textController.clear();
    _focusNode.requestFocus();
  }

  Widget _clearSearchAction() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (context, value, _) {
        if (value.text.isEmpty) return const SizedBox.shrink();
        return IconButton(
          tooltip: context.l10n.searchClear,
          onPressed: _clear,
          icon: const Icon(Icons.clear),
        );
      },
    );
  }

  /// M3 SearchBar look, inline behaviour: no SearchAnchor view. The type
  /// tabs and the filter button must stay visible while typing, and the
  /// suggestions render in the host's body exactly like the pre-M3 page did.
  ///
  /// Keywords a space has closed sit on pills ([SearchKeywordPills]); the
  /// pills lie between the field's fill and its text, so the bar paints
  /// no fill of its own.
  Widget _buildSearchBar(BuildContext context) {
    final bar = SearchBar(
      controller: _textController,
      focusNode: _focusNode,
      // The theme's flat field, sized like [SearchFieldButton] on the
      // guide and the result page: the field reads as one across both
      // pushes.
      constraints: const BoxConstraints(
        minHeight: SearchFieldButton.height,
        maxWidth: SearchFieldButton.maxWidth,
      ),
      backgroundColor: const WidgetStatePropertyAll(FuncTokens.transparent),
      hintText: context.l10n.searchBarHint,
      leading: const Icon(Icons.search),
      trailing: [_clearSearchAction()],
      onSubmitted: (_) => _submit(),
      textInputAction: TextInputAction.search,
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: SearchBarTheme.of(context).backgroundColor?.resolve(const {}),
        shape: const StadiumBorder(),
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _textController,
        builder: (context, value, bar) => SearchKeywordPills(
          text: value.text,
          finishedOnly: true,
          child: bar!,
        ),
        child: bar,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supportsFilters = type != SearchResultType.user;
    return widget.builder(
      context,
      SearchInputEngineParts(
        field: _buildSearchBar(context),
        tabs: AppTabBar(
          controller: _tabController,
          labels: [
            for (final type in _types) searchText(context, type.labelKey),
          ],
        ),
        filterButton: SearchFilterButton(
          filters: supportsFilters ? _filters : IllustSearchFilters.defaults,
          muted: !supportsFilters,
          onPressed: supportsFilters
              ? _editFilters
              : () => showAppSnackBar(
                  context,
                  context.l10n.searchUserFiltersUnavailable,
                ),
        ),
        body: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _textController,
          builder: (context, value, _) => _SearchInputBody(
            value: value,
            type: type,
            onSearch: _search,
            onFill: _fill,
            onComplete: _edit,
            onShortcut: widget.onShortcut,
          ),
        ),
      ),
    );
  }
}

/// Below the input: where to start while the field is empty, the
/// suggestions for the keyword at the caret, or the work or user an id or
/// a link opens.
///
/// A suggestion, a recent search or a trending tag searches on tap; a
/// long press (or a suggestion's trailing button) puts it in the field to
/// edit instead. A suggestion stands in for the keyword at the caret: a
/// tap searches the whole query with it, and putting it in the field adds
/// a space for the next keyword.
class _SearchInputBody extends ConsumerWidget {
  const _SearchInputBody({
    required this.value,
    required this.type,
    required this.onSearch,
    required this.onFill,
    required this.onComplete,
    this.onShortcut,
  });

  final TextEditingValue value;
  final SearchResultType type;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFill;
  final ValueChanged<TextEditingValue> onComplete;

  /// The host's own handling of an id or a link; the full page swaps itself
  /// for what it names, the docked panel closes first (R10).
  final ValueChanged<SearchShortcut>? onShortcut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched before any return: the autocomplete state lives only while
    // the page listens.
    final state = ref.watch(searchAutocompleteProvider);
    final text = value.text;
    if (text.trim().isEmpty) {
      return _SearchStart(type: type, onSearch: onSearch, onFill: onFill);
    }
    final shortcut = searchShortcutFor(text, type);
    if (shortcut != null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
        children: [
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(_shortcutLabel(context, shortcut)),
            onTap: () {
              if (onShortcut case final open?) {
                open(shortcut);
              } else {
                unawaited(swapToSearchShortcut(context, shortcut));
              }
            },
          ),
        ],
      );
    }
    if (state.loading) {
      return const FeedLoading();
    }
    if (state.error != null) {
      return FeedError(
        title: context.l10n.searchLoadFailed,
        error: state.error!,
        retryLabel: context.l10n.searchRetry,
        onRetry: () =>
            ref.read(searchAutocompleteProvider.notifier).update(state.keyword),
        scrollable: false,
      );
    }
    final keyword = keywordAtCaret(value);
    // Right after a space: the next keyword is not started yet.
    if (keyword == null) return const SizedBox.shrink();
    final present = otherKeywords(text, keyword);
    final suggestions = [
      for (final suggestion in state.suggestions)
        if (!present.contains(suggestion.keyword)) suggestion,
    ];
    if (suggestions.isEmpty) {
      return Center(child: Text(context.l10n.searchNoSuggestions));
    }
    void complete(String suggestion) => onComplete(
      replaceKeyword(value, keyword, suggestion, thenSeparate: true),
    );
    // No dividers: rows of one list, like M3's search view.
    return ListView.builder(
      padding: EdgeInsets.only(
        top: FuncSpacing.sm,
        bottom: FuncSpacing.sm + MediaQuery.viewInsetsOf(context).bottom,
      ),
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        return Semantics(
          onLongPressHint: context.l10n.searchSuggestionFill,
          child: ListTile(
            leading: const Icon(Icons.search),
            title: Text(suggestion.displayName),
            subtitle: suggestion.translatedName == null
                ? null
                : Text(suggestion.keyword),
            onTap: () => onSearch(
              replaceKeyword(value, keyword, suggestion.keyword).text.trim(),
            ),
            onLongPress: () {
              AppHaptics.longPress();
              complete(suggestion.keyword);
            },
            trailing: EdgeIconButtons(
              children: [
                IconButton(
                  tooltip: context.l10n.searchSuggestionFill,
                  onPressed: () => complete(suggestion.keyword),
                  icon: const Icon(Icons.north_west),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _shortcutLabel(BuildContext context, SearchShortcut shortcut) {
    final id = shortcut.id;
    return switch (shortcut.kind) {
      SearchShortcutKind.illust => context.l10n.searchOpenIllust(id),
      SearchShortcutKind.novel => context.l10n.searchOpenNovel(id),
      SearchShortcutKind.user => context.l10n.searchOpenUser(id),
    };
  }
}

/// The empty input's start points: recent searches, then the selected
/// kind's trending tags (users have none).
class _SearchStart extends ConsumerWidget {
  const _SearchStart({
    required this.type,
    required this.onSearch,
    required this.onFill,
  });

  final SearchResultType type;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFill;

  /// Two or three rows of tags on a phone; the full grid is on the search
  /// tab.
  static const _trendingShown = 12;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(searchHistoryProvider);
    final trending = type == SearchResultType.user
        ? const <TrendingTag>[]
        : ref.watch(trendingTagsProvider(type)).value ?? const <TrendingTag>[];
    if (history.isEmpty && trending.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: Text(
            l10n.searchHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }
    void fillWithHaptic(String keyword) {
      AppHaptics.longPress();
      onFill(keyword);
    }

    return ListView(
      padding: EdgeInsets.only(
        bottom: FuncSpacing.xl + MediaQuery.viewInsetsOf(context).bottom,
      ),
      children: [
        if (history.isNotEmpty) ...[
          SearchSectionHeader(
            title: l10n.searchHistoryTitle,
            trailing: TextButton(
              onPressed: () => unawaited(_confirmClear(context, ref)),
              child: Text(l10n.searchHistoryClear),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
            child: Wrap(
              spacing: FuncSpacing.sm,
              runSpacing: FuncSpacing.sm,
              children: [
                for (final keyword in history)
                  _HistoryChip(
                    keyword: keyword,
                    onTap: () => onSearch(keyword),
                    onLongPress: () => fillWithHaptic(keyword),
                    onDeleted: () => unawaited(_remove(context, ref, keyword)),
                  ),
              ],
            ),
          ),
        ],
        if (trending.isNotEmpty) ...[
          SearchSectionHeader(title: l10n.searchTrending),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.md),
            child: TagChips(
              children: [
                for (final tag in trending.take(_trendingShown))
                  TagChip(
                    label: tag.name,
                    translated: tag.translatedName,
                    onTap: () => onSearch(tag.name),
                    onLongPress: () => fillWithHaptic(tag.name),
                    onSecondaryTapAt: (position) => unawaited(
                      showDisplayActions(
                        context,
                        position: position,
                        onLongPress: () => fillWithHaptic(tag.name),
                        actions: [
                          DisplayAction(
                            icon: Icons.north_west,
                            label: l10n.searchSuggestionFill,
                            onSelected: () => fillWithHaptic(tag.name),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    String keyword,
  ) async {
    final index = await ref
        .read(searchHistoryProvider.notifier)
        .remove(keyword);
    if (index == null || !context.mounted) return;
    showUndoSnackBar(
      context,
      context.l10n.searchHistoryRemoved,
      onUndo: (container) => container
          .read(searchHistoryProvider.notifier)
          .restore(keyword, index),
    );
  }

  /// Clearing every entry has no undo, so it asks first.
  static Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.searchHistoryClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.searchHistoryClear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(searchHistoryProvider.notifier).clear();
  }
}

/// A recent search: tap searches it again, long press edits it, the
/// trailing cross removes it (with undo).
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.keyword,
    required this.onTap,
    required this.onLongPress,
    required this.onDeleted,
  });

  final String keyword;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) => Semantics(
    onLongPressHint: context.l10n.searchSuggestionFill,
    child: GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTapUp: (details) => unawaited(
        showDisplayActions(
          context,
          position: details.globalPosition,
          onLongPress: onLongPress,
          actions: [
            DisplayAction(
              icon: Icons.north_west,
              label: context.l10n.searchSuggestionFill,
              onSelected: onLongPress,
            ),
          ],
        ),
      ),
      child: InputChip(
        avatar: const Icon(Icons.history),
        label: Text(keyword),
        onPressed: onTap,
        onDeleted: onDeleted,
        deleteButtonTooltipMessage: context.l10n.searchHistoryRemove,
      ),
    ),
  );
}
