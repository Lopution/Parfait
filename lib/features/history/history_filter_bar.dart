import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/navigation/keyboard_back.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/filter_menu_button.dart';
import '../../core/history/history_models.dart';
import '../../l10n/context.dart';

/// Content width at or above which the history control strip places an inline
/// compact [SearchBar] beside the content-type filter menu.
const double kHistoryWideFilterWidth = 520;

/// Adaptive filter and search strip mounted directly under [AppTopBar] on
/// [HistoryPage].
///
/// Uses `FilterMenuButton` (`NAV-17` / D3) for the All / Illustrations / Novels
/// filter. On wide surfaces (`>= kHistoryWideFilterWidth`), renders an inline
/// compact `SearchBar` on the same row; on narrow surfaces, renders a trailing
/// search icon button so the top bar stays uncrowded across all four locales
/// down to 320dp at 1.3x text scale.
class HistoryFilterBar extends StatelessWidget {
  const HistoryFilterBar({
    super.key,
    required this.isWide,
    required this.contentType,
    required this.onContentTypeChanged,
    required this.searchController,
    required this.searchFocusNode,
    required this.narrowSearching,
    required this.onOpenNarrowSearch,
    required this.onFocusWideSearch,
    required this.onQueryChanged,
    required this.onQuerySubmitted,
    required this.onClearQuery,
  });

  final bool isWide;
  final HistoryContentType? contentType;
  final ValueChanged<HistoryContentType?> onContentTypeChanged;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final bool narrowSearching;
  final VoidCallback onOpenNarrowSearch;
  final VoidCallback onFocusWideSearch;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onQuerySubmitted;
  final VoidCallback onClearQuery;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final typeLabel = switch (contentType) {
      null => l10n.historyFilterAll,
      HistoryContentType.illust => l10n.profileIllust,
      HistoryContentType.novel => l10n.profileNovel,
    };
    final typeFilter = FilterMenuButton<HistoryContentType?>(
      key: const ValueKey('history-filter-type'),
      label: typeLabel,
      value: contentType,
      options: [
        AppMenuEntry(
          value: null,
          label: l10n.historyFilterAll,
          icon: AppIcons.history,
        ),
        AppMenuEntry(
          value: HistoryContentType.illust,
          label: l10n.profileIllust,
          icon: AppIcons.illust,
        ),
        AppMenuEntry(
          value: HistoryContentType.novel,
          label: l10n.profileNovel,
          icon: AppIcons.novel,
        ),
      ],
      onChanged: onContentTypeChanged,
    );

    if (isWide) {
      return SearchShortcutAnchor(
        onTrigger: onFocusWideSearch,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.lg,
            FuncSpacing.sm,
            FuncSpacing.lg,
            FuncSpacing.xs,
          ),
          child: Row(
            children: [
              typeFilter,
              const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: searchController,
                      builder: (context, value, _) => SearchBar(
                        key: const ValueKey('history-search-bar'),
                        controller: searchController,
                        focusNode: searchFocusNode,
                        constraints: const BoxConstraints(minHeight: 40),
                        hintText: l10n.historySearchHint,
                        leading: const Icon(AppIcons.search, size: 19),
                        trailing: [
                          if (value.text.isNotEmpty)
                            IconButton(
                              key: const ValueKey('history-search-clear'),
                              tooltip: l10n.searchClear,
                              icon: const Icon(UiIcons.close, size: 18),
                              onPressed: onClearQuery,
                            ),
                        ],
                        onChanged: onQueryChanged,
                        onSubmitted: onQuerySubmitted,
                        textInputAction: TextInputAction.search,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.lg,
        FuncSpacing.xs,
        narrowSearching
            ? FuncSpacing.lg
            : FuncSpacing.lg - EdgeIconButtons.glyphInset,
        FuncSpacing.xs,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: typeFilter),
          if (!narrowSearching)
            SearchShortcutAnchor(
              onTrigger: onOpenNarrowSearch,
              child: IconButton(
                key: const ValueKey('history-search-button'),
                tooltip: l10n.searchTitle,
                onPressed: onOpenNarrowSearch,
                icon: const Icon(AppIcons.search),
              ),
            ),
        ],
      ),
    );
  }
}

/// Top bar shown on narrow screens while history search mode is active.
AppTopBar historySearchTopBar(
  BuildContext context, {
  required TextEditingController controller,
  required FocusNode focusNode,
  required ValueChanged<String> onChanged,
  required ValueChanged<String> onSubmitted,
  required VoidCallback onClear,
  required VoidCallback onExit,
}) {
  final l10n = context.l10n;
  return AppTopBar(
    automaticallyImplyLeading: false,
    leading: IconButton(
      key: const ValueKey('history-search-back'),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: onExit,
      icon: const Icon(UiIcons.arrowBack),
    ),
    titleSpacing: 0,
    title: TextField(
      key: const ValueKey('history-search-field'),
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: l10n.historySearchHint,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
      ),
    ),
    actions: [
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => value.text.isEmpty
            ? const SizedBox.shrink()
            : IconButton(
                key: const ValueKey('history-search-clear'),
                tooltip: l10n.searchClear,
                onPressed: onClear,
                icon: const Icon(UiIcons.close),
              ),
      ),
    ],
  );
}
